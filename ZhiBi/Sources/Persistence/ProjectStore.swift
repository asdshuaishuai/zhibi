import Foundation
import Combine

/// 作品目录里的一份对话归档（chat-archive-*.md）。
struct ChatArchiveEntry: Identifiable, Hashable {
    var id: URL { url }
    var url: URL
    var name: String
    var createdAt: Date
    var bytes: Int

    var sizeLabel: String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    /// 归档面板的本地筛选：文件名 / 日期 / 大小都可以。
    func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let date = createdAt.formatted(date: .abbreviated, time: .shortened).lowercased()
        return name.lowercased().contains(q)
            || date.contains(q)
            || sizeLabel.lowercased().contains(q)
    }
}

/// 全量项目状态。单一权威（oh-story：单一 JSON 权威 + 派生视图）。
/// 一切变更走这里；保存 = 原子落盘。
@MainActor
final class ProjectStore: ObservableObject {
    @Published var project = NovelProject()
    @Published var canonSections: [CanonSection] = []
    @Published var storylines: [Storyline] = []
    @Published var timelineEvents: [TimelineEvent] = []
    @Published var stages: [Stage] = []
    @Published var chapters: [Chapter] = []
    @Published var clues: [Clue] = []
    @Published var facts: [MemoryFact] = []
    @Published var characterAliases: [CharacterAlias] = []
    @Published var dismissedConflicts: [String]? = []
    /// 本书封面（AI 绘制的 SVG，作者采用后持久化为 cover.svg）
    @Published var coverSVG: String?
    /// 长程记忆：章档案卡（每章一张，跨全书可检索）
    @Published var dossiers: [ChapterDossier] = []
    @Published var proposals: [AIProposal] = []
    /// 作者与 AI 的对话（项目级，随书保存；上限 200 条）
    @Published var chatMessages: [ChatMessage] = []
    /// 最近一次保存失败原因（磁盘满/权限等）——UI 状态条展示
    @Published var lastSaveError: String?
    /// 读盘隔离/损坏警告（不随自动保存成功被清掉，需作者确认）
    @Published var loadWarnings: String?
    /// 自动保存开关（由设置页控制；关掉后只走 ⌘S 手动保存）
    var autoSaveEnabled = true
    /// 脏章节集合：saveNow 只落盘这些章（避免全书全量重写）
    private var dirtyChapters: Set<Int> = []

    let rootURL: URL
    private var saveTimer: Timer?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Load / Save

    static func createProject(at url: URL, title: String) throws -> URL {
        let store = ProjectStore(rootURL: url)
        store.project.title = title
        try store.saveNow()
        return url
    }

    /// 同步加载（CLI/导入用；主线程 UI 请用 loadAsync）
    func load() throws {
        try applySnapshot(LoadSnapshot.capture(rootURL: rootURL))
    }

    /// 异步加载：读盘全部在后台执行，主线程只做组装与赋值。
    /// FileProvider/网络卷上逐个同步读会无限期卡住界面（必须异步化）。
    func loadAsync() async throws {
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try LoadSnapshot.capture(rootURL: self.rootURL)
        }.value
        try applySnapshot(snapshot)
    }

    /// 读盘快照：只读、可整体放后台（不触碰 @MainActor 的 self）
    struct LoadSnapshot {
        var project: NovelProject
        var coverSVG: String?
        var canonSections: [CanonSection]
        var storylines: [Storyline]
        var timelineEvents: [TimelineEvent]
        var stages: [Stage]
        var clues: [Clue]
        var memory: MemoryFile?
        var proposals: [AIProposal]
        var dossiers: [ChapterDossier]
        var chatMessages: [ChatMessage]
        var chapters: [Chapter]
        var quarantineNotes: [String]

        static func capture(rootURL: URL) throws -> LoadSnapshot {
            let project = try Disk.readJSON(NovelProject.self, from: ProjectLayout.projectFile(rootURL))
        let coverSVG: String? = {
            let f = rootURL.appendingPathComponent("cover.svg")
            guard FileManager.default.fileExists(atPath: f.path) else { return nil }
            return try? String(contentsOf: f, encoding: .utf8)
        }()
            var quarantineNotes: [String] = []
            let sectionsFile = ProjectLayout.canonDir(rootURL).appendingPathComponent("sections.json")
            let canonRead = Disk.readJSONOrQuarantine([CanonSection].self, from: sectionsFile, label: "设定索引")
            if let note = canonRead.note { quarantineNotes.append(note) }
            let canon: [CanonSection]
            if let loaded = canonRead.value {
                canon = loaded
            } else {
                // 文件缺失或已隔离：从 canon/*.md 重建（内容仍在，至少不丢文档）
                canon = ProjectStore.loadCanonFromDisk(rootURL: rootURL)
            }
            func read<T: Decodable>(_ type: T.Type, _ url: URL, _ label: String, fallback: T) -> T {
                let r = Disk.readJSONOrQuarantine(type, from: url, label: label)
                if let note = r.note { quarantineNotes.append(note) }
                return r.value ?? fallback
            }
            let storylines = read([Storyline].self, ProjectLayout.storylinesFile(rootURL), "故事线", fallback: [])
            let timelineEvents = read([TimelineEvent].self, ProjectLayout.eventsFile(rootURL), "时间线事件", fallback: [])
            let stages = read([Stage].self, ProjectLayout.stagesFile(rootURL), "阶段", fallback: [])
            let clues = read([Clue].self, ProjectLayout.cluesFile(rootURL), "伏笔台账", fallback: [])
            let memory = Disk.readJSONOrQuarantine(MemoryFile.self, from: ProjectLayout.memoryFile(rootURL), label: "记忆库")
            if let note = memory.note { quarantineNotes.append(note) }
            let dossiers = read([ChapterDossier].self, ProjectLayout.dossiersFile(rootURL), "档案卡", fallback: [])
            let chatMessages = read([ChatMessage].self, ProjectLayout.chatFile(rootURL), "对话记录", fallback: [])
            let pending = read([AIProposal].self, ProjectLayout.proposalsFile(rootURL), "提案收件箱", fallback: [])
            let archived = read([AIProposal].self, ProjectLayout.proposalsArchiveFile(rootURL), "提案归档", fallback: [])
            let proposals = (pending + archived).sorted { $0.createdAt > $1.createdAt }

            var loaded: [Chapter] = []
            let fm = FileManager.default
            if let dirs = try? fm.contentsOfDirectory(at: ProjectLayout.chaptersDir(rootURL), includingPropertiesForKeys: nil) {
                for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("ch-") {
                    guard let num = Int(dir.lastPathComponent.dropFirst(3)) else { continue }
                    let proseFile = ProjectLayout.proseFile(rootURL, number: num)
                    let metaResult = ProjectStore.loadChapterMeta(rootURL: rootURL, number: num,
                                                                  proseFileMissing: !fm.fileExists(atPath: proseFile.path))
                    var ch = metaResult.chapter
                    if let note = metaResult.note { quarantineNotes.append(note) }
                    // 正文读不了（非 UTF-8 等）：原稿隔离为 .corrupt，绝不静默清空后覆盖
                    if fm.fileExists(atPath: proseFile.path) {
                        let (text, quarantined) = Disk.readTextOrQuarantine(proseFile)
                        ch.prose = text
                        if quarantined != nil {
                            quarantineNotes.append("第\(num)章正文不是 UTF-8 文本，已保留为 .corrupt（未丢失）。")
                        }
                    }
                    loaded.append(ch)
                }
            }
            return LoadSnapshot(project: project, coverSVG: coverSVG, canonSections: canon, storylines: storylines,
                                timelineEvents: timelineEvents, stages: stages, clues: clues, memory: memory.value,
                                proposals: proposals, dossiers: dossiers, chatMessages: chatMessages,
                                chapters: loaded, quarantineNotes: quarantineNotes)
        }
    }

    /// 主线程应用快照（唯一的 store 变更点）
    @discardableResult
    func applySnapshot(_ snapshot: LoadSnapshot) throws -> Bool {
        self.project = snapshot.project
        self.coverSVG = snapshot.coverSVG
        self.canonSections = snapshot.canonSections
        self.storylines = snapshot.storylines
        self.timelineEvents = snapshot.timelineEvents.sorted { ($0.chapter, $0.id) < ($1.chapter, $1.id) }
        self.stages = snapshot.stages.sorted { $0.id < $1.id }
        self.clues = snapshot.clues.sorted { $0.id < $1.id }
        self.facts = snapshot.memory?.facts ?? []
        self.characterAliases = snapshot.memory?.aliases ?? []
        self.dismissedConflicts = snapshot.memory?.dismissedConflicts ?? []
        self.proposals = snapshot.proposals
        self.dossiers = snapshot.dossiers
        self.chatMessages = Array(snapshot.chatMessages.suffix(200))
        self.chapters = snapshot.chapters.sorted { $0.number < $1.number }
        dirtyChapters.removeAll()
        if !snapshot.quarantineNotes.isEmpty {
            loadWarnings = snapshot.quarantineNotes.joined(separator: " ")
            // 隔离过的正文：写签名失效，强制下次保存真正落盘
            for ch in snapshot.chapters where ch.prose.isEmpty {
                Disk.invalidateSignature(ProjectLayout.proseFile(rootURL, number: ch.number))
            }
        } else {
            loadWarnings = nil
        }
        return true
    }

    func loadSync() throws {
        var quarantineNotes: [String] = []
        func read<T: Decodable>(_ type: T.Type, _ url: URL, _ label: String, fallback: T) -> T {
            let r = Disk.readJSONOrQuarantine(type, from: url, label: label)
            if let note = r.note { quarantineNotes.append(note) }
            return r.value ?? fallback
        }
        let sectionsFile = ProjectLayout.canonDir(rootURL).appendingPathComponent("sections.json")
        let canonRead = Disk.readJSONOrQuarantine([CanonSection].self, from: sectionsFile, label: "设定索引")
        if let note = canonRead.note { quarantineNotes.append(note) }
        canonSections = canonRead.value ?? Self.loadCanonFromDisk(rootURL: rootURL)
        storylines = read([Storyline].self, ProjectLayout.storylinesFile(rootURL), "故事线", fallback: [])
        timelineEvents = read([TimelineEvent].self, ProjectLayout.eventsFile(rootURL), "时间线事件", fallback: [])
        stages = read([Stage].self, ProjectLayout.stagesFile(rootURL), "阶段", fallback: [])
        clues = read([Clue].self, ProjectLayout.cluesFile(rootURL), "伏笔台账", fallback: [])
        let memoryRead = Disk.readJSONOrQuarantine(MemoryFile.self, from: ProjectLayout.memoryFile(rootURL), label: "记忆库")
        if let note = memoryRead.note { quarantineNotes.append(note) }
        let mem = memoryRead.value
        facts = mem?.facts ?? []
        characterAliases = mem?.aliases ?? []
        dismissedConflicts = mem?.dismissedConflicts ?? []
        let pendingLoaded = read([AIProposal].self, ProjectLayout.proposalsFile(rootURL), "提案收件箱", fallback: [])
        let archivedLoaded = read([AIProposal].self, ProjectLayout.proposalsArchiveFile(rootURL), "提案归档", fallback: [])
        proposals = (pendingLoaded + archivedLoaded).sorted { $0.createdAt > $1.createdAt }
        chatMessages = Array(read([ChatMessage].self, ProjectLayout.chatFile(rootURL), "对话记录", fallback: []).suffix(200))

        var loaded: [Chapter] = []
        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: ProjectLayout.chaptersDir(rootURL), includingPropertiesForKeys: nil) {
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("ch-") {
                guard let num = Int(dir.lastPathComponent.dropFirst(3)) else { continue }
                let proseFile = ProjectLayout.proseFile(rootURL, number: num)
                let metaResult = Self.loadChapterMeta(rootURL: rootURL, number: num,
                                                      proseFileMissing: !fm.fileExists(atPath: proseFile.path))
                var ch = metaResult.chapter
                if let note = metaResult.note { quarantineNotes.append(note) }
                // 正文读不了（非 UTF-8 等）：原稿隔离为 .corrupt，绝不静默清空后覆盖
                if fm.fileExists(atPath: proseFile.path) {
                    let (text, quarantined) = Disk.readTextOrQuarantine(proseFile)
                    ch.prose = text
                    if let q = quarantined {
                        quarantineNotes.append("第\(num)章正文不是 UTF-8 文本，已保留为 \(q.lastPathComponent)（未丢失）。")
                        Disk.invalidateSignature(proseFile)
                    }
                }
                loaded.append(ch)
            }
        }
        loadWarnings = quarantineNotes.isEmpty ? nil : quarantineNotes.joined(separator: " ")
        timelineEvents.sort { ($0.chapter, $0.id) < ($1.chapter, $1.id) }
        stages.sort { $0.id < $1.id }
        clues.sort { $0.id < $1.id }
        loaded.sort { $0.number < $1.number }
        chapters = loaded
        dirtyChapters.removeAll()
    }

    /// canon 目录下的人写 markdown（人可手改的设定文件）
    nonisolated private static func loadCanonFromDisk(rootURL: URL) -> [CanonSection] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: ProjectLayout.canonDir(rootURL), includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                // 非 UTF-8 的设定 md：隔离原文件并保留 latin1 可读内容，不能静默变空
                let (text, _) = Disk.readTextOrQuarantine($0)
                return CanonSection(title: $0.deletingPathExtension().lastPathComponent, content: text)
            }
    }

    func saveSoon() {
        guard autoSaveEnabled else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                do {
                    try self?.saveNow()
                    self?.lastSaveError = nil
                } catch {
                    self?.lastSaveError = "自动保存失败：\(error.localizedDescription)——请手动 ⌘S 重试"
                }
            }
        }
    }

    /// 退出时的强制保存（无视 autoSaveEnabled）
    func saveNow_forced() {
        do { try saveNow(); lastSaveError = nil } catch { lastSaveError = error.localizedDescription }
    }

    func saveNow() throws {
        // 章节正文最先写——只落盘脏章节，它是作者最不可再生的数据
        // meta.json 不再内嵌正文（prose.md 才是权威），磁盘减半
        struct MetaChapter: Codable {
            var id: UUID
            var number: Int
            var title: String
            var status: ChapterStatus
            var skeleton: ChapterSkeleton?
            var summary: ChapterSummary?
            var notes: [String]?
            var directive: String?
            var cachedWords: Int?
            var updatedAt: Date
        }
        for ch in chapters where dirtyChapters.contains(ch.number) {
            let meta = MetaChapter(id: ch.id, number: ch.number, title: ch.title, status: ch.status,
                                   skeleton: ch.skeleton, summary: ch.summary, notes: ch.notes,
                                   directive: ch.directive, cachedWords: ch.cachedWords, updatedAt: ch.updatedAt)
            try Disk.writeJSON(meta, to: Self.chapterMetaURL(rootURL, ch.number))
            try Disk.write(Data(ch.prose.utf8), to: ProjectLayout.proseFile(rootURL, number: ch.number))
        }
        // 日账只留最近一年：否则 project.json 会随天数无限增长
        if let daily = project.dailyWords, daily.count > 400 {
            let keep = Set(daily.keys.sorted().suffix(366))
            project.dailyWords = daily.filter { keep.contains($0.key) }
        }
        try Disk.writeJSON(project, to: ProjectLayout.projectFile(rootURL))
        // 封面 SVG（AI 绘制/作者采用后落盘；无封面不写文件）
        if let svg = coverSVG {
            try Disk.write(Data(svg.utf8), to: rootURL.appendingPathComponent("cover.svg"))
        }
        // canon 每节同步导出为可手改的 md（派生视图）；孤儿 md（用户手工放入）自动导入为新节。
        // 顺序：先算「本次将写出的真实文件名集合」（含同名 -x 后缀），再导入孤儿
        // （排除这些名字），再写 sections.json，最后写 md。否则同名节会每次保存
        // 把 -x 副本当孤儿吃回来，节数无限 +1。
        let canonDir = ProjectLayout.canonDir(rootURL)
        var writtenNames = Set<String>()
        // 用与 canonSections 同下标的数组：同题设定不能用 title 做字典键，
        // 否则后一个会覆盖前一个的文件名，导致两节写进同一个 md、丢一节。
        var sectionFileNames: [String] = []
        for section in canonSections {
            var name = ProjectLayout.safeFileName(section.title)
            while writtenNames.contains(name + ".md") { name += "-x" }
            writtenNames.insert(name + ".md")
            sectionFileNames.append(name)
        }
        if let existing = try? FileManager.default.contentsOfDirectory(at: canonDir, includingPropertiesForKeys: nil) {
            for f in existing.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where f.pathExtension == "md" && !writtenNames.contains(f.lastPathComponent) {
                if let text = try? String(contentsOf: f, encoding: .utf8) {
                    let title = f.deletingPathExtension().lastPathComponent
                    canonSections.append(CanonSection(title: title, content: text, certainty: .tentative))
                    var name = title
                    while writtenNames.contains(name + ".md") { name += "-x" }
                    writtenNames.insert(name + ".md")
                    sectionFileNames.append(name)
                }
            }
        }
        try Disk.writeJSON(canonSections, to: canonDir.appendingPathComponent("sections.json"))
        // 每节 md：内容没变就跳过写（省 iCloud 上传/主线程）；单节失败不中断保存
        var canonWriteFailed = false
        for (idx, section) in canonSections.enumerated() {
            let name = idx < sectionFileNames.count ? sectionFileNames[idx] : ProjectLayout.safeFileName(section.title)
            let url = canonDir.appendingPathComponent(name + ".md")
            do {
                let existing = try? String(contentsOf: url, encoding: .utf8)
                if existing == section.content { continue }
                try Disk.write(Data(section.content.utf8), to: url)
            } catch {
                canonWriteFailed = true
                lastSaveError = "设定「\(section.title)」的 md 导出失败：\(error.localizedDescription)"
            }
        }
        try Disk.writeJSON(storylines, to: ProjectLayout.storylinesFile(rootURL))
        try Disk.writeJSON(timelineEvents, to: ProjectLayout.eventsFile(rootURL))
        try Disk.writeJSON(stages, to: ProjectLayout.stagesFile(rootURL))
        try Disk.writeJSON(clues, to: ProjectLayout.cluesFile(rootURL))
        try Disk.writeJSON(MemoryFile(facts: facts, aliases: characterAliases, dismissedConflicts: dismissedConflicts), to: ProjectLayout.memoryFile(rootURL))
        // 提案热/冷分离：inbox 只存待审（每次编辑都重编码的活跃集）；已裁决进 archive
        // （大草案含全文，全量重编码在 1000+ 提案时约 21ms/次且文件 10MB+）
        let pendingProposals = proposals.filter { $0.status == .pending }
        let archivedProposals = proposals.filter { $0.status != .pending }
        try Disk.writeJSON(pendingProposals, to: ProjectLayout.proposalsFile(rootURL))
        // 归档必须无条件写（空数组也要写）：否则「清空已裁决」只清了内存，
        // 旧 archive.json 还在盘上，下次打开会把刚清掉的提案全部复活。
        try Disk.writeJSON(archivedProposals, to: ProjectLayout.proposalsArchiveFile(rootURL))
        try Disk.writeJSON(dossiers, to: ProjectLayout.dossiersFile(rootURL))
        try Disk.writeJSON(Array(chatMessages.suffix(200)), to: ProjectLayout.chatFile(rootURL))
        dirtyChapters.removeAll()
        if canonWriteFailed {
            // 其余账本已全部落盘；把单节 md 导出失败升级为可展示的错误（不阻塞保存本身）
            throw NSError(domain: "ZhiBi.ProjectStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: lastSaveError ?? "设定 md 导出失败"])
        }
    }

    nonisolated private static func chapterMetaURL(_ root: URL, _ n: Int) -> URL {
        ProjectLayout.chapterDir(root, number: n).appendingPathComponent("meta.json")
    }

    /// 旧版把正文内嵌在 meta.json（后来才拆成 prose.md）。prose.md 缺失时才回退取它。
    private struct LegacyMetaProse: Codable { var prose: String? }

    /// 读一章的 meta。**必须用 ChapterMeta 解**：meta.json 里没有 prose 键，
    /// 而 Chapter.prose 是非可选字段，用 Chapter 解必然抛 keyNotFound，
    /// 被 `?? Chapter(number:)` 吞掉之后，每章的状态/骨架/摘要/随手记都会静默退化成默认值——
    /// 表现就是「打开工程后骨架全没了」，再自动保存就从盘上永久抹掉。
    nonisolated static func loadChapterMeta(rootURL: URL, number n: Int,
                                            proseFileMissing: Bool) -> (chapter: Chapter, note: String?) {
        let url = chapterMetaURL(rootURL, n)
        let (meta, note) = Disk.readJSONOrQuarantine(ChapterMeta.self, from: url,
                                                     label: "第\(n)章 meta")
        guard let meta else {
            // 解不出来时原文件已被隔离：返回空章让作者看见，但绝不把默认值写回覆盖原档
            return (Chapter(number: n), note)
        }
        var ch = Chapter(number: n)
        ch.id = meta.id
        ch.title = meta.title
        ch.status = meta.status
        ch.skeleton = meta.skeleton
        ch.summary = meta.summary
        ch.notes = meta.notes
        ch.directive = meta.directive
        ch.cachedWords = meta.cachedWords
        ch.updatedAt = meta.updatedAt
        if proseFileMissing, let legacy = try? Disk.readJSON(LegacyMetaProse.self, from: url) {
            ch.prose = legacy.prose ?? ""
        }
        return (ch, note)
    }

    // MARK: - 章节操作

    @discardableResult
    func ensureChapter(_ number: Int) -> Chapter {
        if let ch = chapters.first(where: { $0.number == number }) { return ch }
        let ch = Chapter(number: number)
        chapters.append(ch)
        chapters.sort { $0.number < $1.number }
        dirtyChapters.insert(number)
        saveSoon()
        return ch
    }

    func chapter(_ number: Int) -> Chapter? { chapters.first { $0.number == number } }

    /// 更新章节；countWords=false 时不计入每日写作账（如批量导入）
    func updateChapter(_ number: Int, countWords: Bool = true, _ mutate: (inout Chapter) -> Void) {
        guard let idx = chapters.firstIndex(where: { $0.number == number }) else { return }
        let oldCount = chapters[idx].wordCount
        let oldStatus = chapters[idx].status
        let oldProse = chapters[idx].prose
        mutate(&chapters[idx])
        // 正文被改动、而调用方没有显式给新状态 → 旧的验证/润色/定稿结论失效
        if chapters[idx].prose != oldProse, chapters[idx].status == oldStatus,
           oldStatus == .checked || oldStatus == .polished || oldStatus == .done {
            chapters[idx].status = .writing
        }
        chapters[idx].updatedAt = Date()
        chapters[idx].cachedWords = WordStats.chineseCount(chapters[idx].prose)
        if countWords {
            let delta = chapters[idx].wordCount - oldCount
            if delta != 0 { accumulateDailyWords(delta) }
        }
        dirtyChapters.insert(number)
        saveSoon()
    }

    private static let todayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func todayKey(_ date: Date = Date()) -> String {
        Self.todayKeyFormatter.string(from: date)
    }

    private func accumulateDailyWords(_ delta: Int) {
        let key = Self.todayKey()
        var daily = project.dailyWords ?? [:]
        daily[key, default: 0] += delta
        project.dailyWords = daily
    }

    /// 今日净增字数（含当天所有章节）
    func todayWordCount() -> Int {
        project.dailyWords?[Self.todayKey()] ?? 0
    }

    func deleteChapter(_ number: Int) {
        let dir = ProjectLayout.chapterDir(rootURL, number: number)
        // 先移废纸篓，成功后再改内存：废纸篓失败时绝不能回退成永久删除
        if FileManager.default.fileExists(atPath: dir.path), !Self.moveToTrash(dir) {
            lastSaveError = "删除中止：章节目录无法移入废纸篓（检查权限/磁盘），未做任何删除。"
            return
        }
        chapters.removeAll { $0.number == number }
        timelineEvents.removeAll { $0.chapter == number }
        dossiers.removeAll { $0.chapter == number }
        dirtyChapters.remove(number)
        // 目录进废纸篓后，写签名缓存必须失效：否则重新导入同内容的章节时
        // Disk.write 会以「字节没变」为由跳过，prose.md 根本不会重建。
        Disk.invalidateSignature(ProjectLayout.proseFile(rootURL, number: number))
        Disk.invalidateSignature(Self.chapterMetaURL(rootURL, number))
        saveSoon()
    }

    /// 删除走废纸篓（可恢复）。返回 false = 无法移入废纸篓，调用方必须中止删除。
    @discardableResult
    static func moveToTrash(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    var currentChapter: Int {
        let drafted = chapters.filter { $0.status != .empty && $0.status != .skeletoned }.map(\.number).max() ?? 0
        return drafted + 1
    }

    // MARK: - 作者 ↔ AI 对话

    func appendChatMessage(_ message: ChatMessage) {
        chatMessages.append(message)
        if chatMessages.count > 200 { chatMessages.removeFirst(chatMessages.count - 200) }
        // 对话是独立小文件：立即落盘，避免“关自动保存/快速退出”时丢掉刚聊完的内容
        saveChatNow()
    }

    /// 重新回答前撤掉上一条回复；问题本身保留，避免对话里堆两层相同提问。
    @discardableResult
    func removeLastChatMessage() -> ChatMessage? {
        guard let last = chatMessages.popLast() else { return nil }
        saveChatNow()
        return last
    }

    func clearChat() {
        chatMessages.removeAll()
        saveChatNow()
    }

    /// 导出对话为 Markdown（作者在保存面板里选路径）。
    func exportChat(to url: URL) throws {
        let markdown = ChatTranscript.markdown(messages: chatMessages, projectTitle: project.title,
                                               proposals: proposals)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 归档到作品目录并清空 chat.json；写失败时保持对话不动。
    /// 返回归档文件 URL；没有对话或写入失败返回 nil（失败原因进 lastSaveError）。
    @discardableResult
    func archiveChat() -> URL? {
        guard !chatMessages.isEmpty else { return nil }
        let baseName = ChatTranscript.archiveFileName()
        var url = rootURL.appendingPathComponent(baseName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let name = baseName.replacingOccurrences(of: ".md", with: "-\(suffix).md")
            url = rootURL.appendingPathComponent(name)
            suffix += 1
        }
        do {
            let markdown = ChatTranscript.markdown(messages: chatMessages, projectTitle: project.title,
                                                   proposals: proposals)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastSaveError = "对话归档失败：\(error.localizedDescription)"
            return nil
        }
        // 可恢复快照与 Markdown 同名；写失败不影响人类可读归档，只是恢复按钮不可用。
        let payloadURL = url.deletingPathExtension().appendingPathExtension("json")
        let payload = ChatArchivePayload(projectTitle: project.title,
                                         messages: chatMessages, proposals: proposals)
        try? Disk.writeJSON(payload, to: payloadURL)
        chatMessages.removeAll()
        saveChatNow()
        return url
    }

    // MARK: - 归档浏览

    /// 列出作品目录里的对话归档，按时间倒序。
    func listChatArchives() -> [ChatArchiveEntry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("chat-archive-") && $0.pathExtension == "md" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { return nil }
                return ChatArchiveEntry(
                    url: url,
                    name: url.lastPathComponent,
                    createdAt: values?.contentModificationDate ?? .distantPast,
                    bytes: values?.fileSize ?? 0)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func readChatArchive(_ url: URL) -> String? {
        guard isChatArchive(url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 与 Markdown 同名的可恢复 JSON；没有或不是普通文件时返回 nil。
    func chatArchivePayloadURL(for url: URL) -> URL? {
        guard isChatArchive(url) else { return nil }
        let candidate = url.deletingPathExtension().appendingPathExtension("json")
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        return candidate
    }

    func readChatArchivePayload(_ url: URL) -> ChatArchivePayload? {
        guard let payloadURL = chatArchivePayloadURL(for: url) else { return nil }
        return try? Disk.readJSON(ChatArchivePayload.self, from: payloadURL)
    }

    /// 把归档消息追加到当前对话（不重新登记提案）。
    /// 返回追加条数；没有可恢复快照返回 nil。
    @discardableResult
    func restoreChatArchive(_ url: URL) -> Int? {
        guard let payload = readChatArchivePayload(url), !payload.messages.isEmpty else { return nil }
        // 同一份归档重复恢复时按消息 ID 去重：ForEach 的 id 必须唯一。
        let existing = Set(chatMessages.map(\.id))
        let incoming = payload.messages.filter { !existing.contains($0.id) }
        guard !incoming.isEmpty else { return 0 }
        chatMessages.append(contentsOf: incoming)
        if chatMessages.count > 200 {
            chatMessages.removeFirst(chatMessages.count - 200)
        }
        saveChatNow()
        return incoming.count
    }

    /// 只允许删除作品目录内、以 chat-archive- 开头且存在的 .md 文件；连同同名 JSON 快照一起删。
    @discardableResult
    func deleteChatArchive(_ url: URL) -> Bool {
        guard isChatArchive(url) else { return false }
        let payloadURL = chatArchivePayloadURL(for: url)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            lastSaveError = "删除对话归档失败：\(error.localizedDescription)"
            return false
        }
        if let payloadURL { try? FileManager.default.removeItem(at: payloadURL) }
        return true
    }

    /// 批量删除；返回真正删除的份数（不合法的路径会被逐条跳过）。
    @discardableResult
    func deleteChatArchives(_ urls: [URL]) -> Int {
        var deleted = 0
        for url in urls where deleteChatArchive(url) { deleted += 1 }
        return deleted
    }

    private func isChatArchive(_ url: URL) -> Bool {
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        let root = rootURL.standardizedFileURL
        guard folder.path == root.path,
              url.lastPathComponent.hasPrefix("chat-archive-"),
              url.pathExtension == "md" else { return false }
        // 必须是普通文件：否则同名的目录会被 removeItem 整个递归删掉。
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    /// 只写 chat.json（不动整本书的账本）；失败进 lastSaveError，仍可通过 ⌘S 重试
    func saveChatNow() {
        do {
            try Disk.writeJSON(Array(chatMessages.suffix(200)), to: ProjectLayout.chatFile(rootURL))
        } catch {
            lastSaveError = "对话记录保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 伏笔

    func nextClueID() -> String {
        let maxN = clues.compactMap { c -> Int? in
            guard c.id.hasPrefix("F"), let n = Int(c.id.dropFirst()) else { return nil }
            return n
        }.max() ?? 0
        return String(format: "F%02d", maxN + 1)
    }

    func nextEventID() -> String {
        let maxN = timelineEvents.compactMap { e -> Int? in
            guard e.id.hasPrefix("E"), let n = Int(e.id.dropFirst()) else { return nil }
            return n
        }.max() ?? 0
        return String(format: "E%02d", maxN + 1)
    }

    func nextStorylineID() -> String {
        let maxN = storylines.compactMap { l -> Int? in
            guard l.id.hasPrefix("L"), let n = Int(l.id.dropFirst()) else { return nil }
            return n
        }.max() ?? 0
        return String(format: "L%02d", maxN + 1)
    }

    /// 活跃伏笔 due-list（NarraCat：major 全部 + medium 限本卷 + small 限近程）
    func activeClues(currentChapter: Int) -> [Clue] {
        clues.filter { $0.status == .planted || $0.status == .developing }
            .sorted { a, b in
                let ao = a.isOverdue(currentChapter: currentChapter), bo = b.isOverdue(currentChapter: currentChapter)
                if ao != bo { return ao }
                return a.lastActionChapter < b.lastActionChapter
            }
    }

    // MARK: - 提案收件箱

    func addProposal(_ p: AIProposal) {
        proposals.insert(p, at: 0)
        saveSoon()
    }

    /// 上一次采纳的未入库清单（收件箱据此提示；清空于下次成功采纳）
    @Published var lastAcceptIssues: String?

    /// 采纳提案。返回 true = 全部入库并已标记采纳；false = 未入库或部分入库（提案保持 pending）。
    /// 调用方必须看返回值，不能假设"点过就算写入"。
    @discardableResult
    func acceptProposal(_ id: UUID) -> Bool {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return false }
        guard proposals[idx].status == .pending else { return false }  // 防重复采纳覆盖手改
        let p = proposals[idx]
        let outcome = applyPayloadDetailed(p.payload, chapter: p.chapterNumber)
        guard outcome.applied > 0 else {
            // 完全没入库：保持 pending（否则提案从待审列表消失且永不可再采纳）
            lastAcceptIssues = "未采纳：\(outcome.summary)"
            return false
        }
        guard outcome.isFullSuccess else {
            // 全无或部分入库：部分成功时也保持 pending——已入库的部分有幂等保护
            // （事件/故事线按 id 去重、设定同题保护、伏笔同 id 合并），重试不会重复
            lastAcceptIssues = "部分采纳：\(outcome.summary)。提案保持待审——修好未入库项后可再点采纳（已入库项不会重复）。"
            return false
        }
        lastAcceptIssues = nil
        proposals[idx].status = .accepted
        proposals[idx].decidedAt = Date()
        saveSoon()
        return true
    }

    func rejectProposal(_ id: UUID, reason: String? = nil) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[idx].status = .rejected
        proposals[idx].decidedAt = Date()
        proposals[idx].rejectReason = reason
        saveSoon()
    }

    /// 误拒绝恢复：重新待审（拒绝是不可逆操作里唯一必须给撤销口子的）
    func reopenProposal(_ id: UUID) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[idx].status = .pending
        proposals[idx].decidedAt = nil
        saveSoon()
    }

    /// 落库结果：applied=实际入库条数；skipped=未入库清单（人话原因）。
    /// 采纳决策据此判定：全部成功才标「已采纳」；部分失败保持待审并展示清单。
    struct ApplyOutcome {
        var applied = 0
        var skipped: [String] = []
        var total = 0
        var isFullSuccess: Bool { skipped.isEmpty }
        var summary: String {
            if skipped.isEmpty { return "已全部入库（\(applied) 项）" }
            return "入库 \(applied)/\(total) 项；未入库 \(skipped.count) 项：\(skipped.prefix(3).joined(separator: "；"))\(skipped.count > 3 ? "…" : "")"
        }
    }

    /// 采纳提案 = 把 payload 写入权威状态（宿主裁决的唯一入口）
    /// 返回 false = 完全未入库（调用方应保持提案 pending 而不是标记已采纳）
    @discardableResult
    func applyPayload(_ payload: ProposalPayload, chapter: Int?) -> Bool {
        applyPayloadDetailed(payload, chapter: chapter).isFullSuccess
    }

    /// 明细版：部分失败时不标已采纳的判定依据（全链路可解释）
    @discardableResult
    func applyPayloadDetailed(_ payload: ProposalPayload, chapter: Int?) -> ApplyOutcome {
        var outcome = ApplyOutcome()
        switch payload {
        case .outlineEvents(let events):
            for raw in events {
                var e = raw
                if e.id.isEmpty { e.id = nextEventID() }
                outcome.total += 1
                // 生产端已保证 E 号全局唯一；这里再按 id|chapter 查重会放进重复 E 号
                if timelineEvents.contains(where: { $0.id == e.id }) {
                    outcome.skipped.append("事件 [\(e.id)] 已存在（编号撞号）")
                } else {
                    timelineEvents.append(e)
                    outcome.applied += 1
                }
            }
            timelineEvents.sort { ($0.chapter, $0.id) < ($1.chapter, $1.id) }
        case .storylines(let lines):
            for raw in lines {
                var l = raw
                if l.id.isEmpty { l.id = nextStorylineID() }
                outcome.total += 1
                if storylines.contains(where: { $0.id == l.id }) {
                    outcome.skipped.append("故事线 [\(l.id)] 已存在（编号撞号）")
                } else {
                    storylines.append(l)
                    outcome.applied += 1
                }
            }
        case .clues(let newClues):
            for raw in newClues {
                var c = raw
                outcome.total += 1
                guard !c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    outcome.skipped.append("伏笔标题为空，未登记")
                    continue
                }
                if c.id.isEmpty { c.id = nextClueID() }
                if let idx = clues.firstIndex(where: { $0.id == c.id }) {
                    // 编号撞号时保护作者已维护的台账：状态/动作日志/埋设信息不被 AI 版本覆盖
                    var merged = c
                    let existing = clues[idx]
                    let authorTouched = !existing.actions.isEmpty || existing.status != .planted
                        || !existing.plantedQuote.isEmpty || existing.targetPayoffChapter != nil
                    if authorTouched {
                        merged.status = existing.status
                        merged.actions = existing.actions
                        merged.lastActionChapter = existing.lastActionChapter
                        if !existing.plantedQuote.isEmpty { merged.plantedQuote = existing.plantedQuote }
                        if let target = existing.targetPayoffChapter { merged.targetPayoffChapter = target }
                    }
                    clues[idx] = merged
                } else {
                    clues.append(c)
                }
                outcome.applied += 1
            }
            clues.sort { $0.id < $1.id }
        case .skeleton(let sk):
            guard let n = chapter, n > 0, self.chapter(n) != nil else {
                outcome.skipped.append("提案缺少有效章节号（章节可能已删除）")
                return outcome
            }
            guard !sk.beats.isEmpty else {
                outcome.skipped.append("骨架没有任何节拍，未写入")
                return outcome
            }
            updateChapter(n) { $0.skeleton = sk; if $0.status == .empty { $0.status = .skeletoned } }
            // 骨架是写前契约，不是已发生的事实：这里只落骨架，**不碰伏笔台账**。
            // 触点合同由 Validator 对着正文验收；台账的推进/回收只能由作者或正文对账写入。
            outcome.total += 1
            outcome.applied += 1
        case .draft(let draft):
            // 作者采纳草稿才走到这里；覆盖前自动快照，快照失败则中止采纳（旧稿保住，提案保持待审）
            guard let n = chapter, n > 0, self.chapter(n) != nil else {
                outcome.skipped.append("提案缺少有效章节号（章节可能已删除）")
                return outcome
            }
            guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                outcome.skipped.append("草稿正文为空，未覆盖正文")
                return outcome
            }
            if let existing = self.chapter(n), !existing.prose.isEmpty {
                guard snapshotProse(chapter: n, tag: "采纳草稿前") != nil else {
                    lastSaveError = "采纳中止：快照写入失败（检查磁盘/权限），草稿仍在收件箱"
                    outcome.skipped.append("快照写入失败，草稿未覆盖")
                    return outcome
                }
            }
            outcome.total += 1
            updateChapter(n) {
                $0.prose = draft.text
                // 新稿覆盖旧稿后，旧的「已验证/已润色/定稿」结论失效——状态必须退回初稿
                $0.status = .written
            }
            outcome.applied += 1
        case .memoryPack(let newFacts, let summary, let newClues):
            // 章节 guard 前置：避免半途 append 后失败导致重复追加
            guard let n = chapter, n > 0, self.chapter(n) != nil else {
                outcome.skipped.append("提案缺少有效章节号（章节可能已删除）")
                return outcome
            }
            outcome.total += 1
            for f in newFacts where !facts.contains(where: { $0.subject == f.subject && $0.predicate == f.predicate && $0.object == f.object }) {
                facts.append(f)
            }
            for c in newClues {
                if let idx = clues.firstIndex(where: { $0.id == c.id }) {
                    // 与既有伏兵合并：台账字段以作者维护为准（status/actions/lastActionChapter 不被 AI 版本抹掉）
                    var merged = c
                    let existing = clues[idx]
                    let authorTouched = !existing.actions.isEmpty || existing.status != .planted
                        || !existing.plantedQuote.isEmpty || existing.targetPayoffChapter != nil
                    if authorTouched {
                        merged.status = existing.status
                        merged.actions = existing.actions
                        merged.lastActionChapter = existing.lastActionChapter
                        if !existing.plantedQuote.isEmpty { merged.plantedQuote = existing.plantedQuote }
                        if let target = existing.targetPayoffChapter { merged.targetPayoffChapter = target }
                    }
                    clues[idx] = merged
                } else {
                    var cand = c
                    if cand.id.isEmpty { cand.id = nextClueID() }
                    clues.append(cand)
                }
            }
            // 记忆回笼后做确定性整理：去重 + 按别名归一主语（不做任何 AI 判断）
            let consolidated = MemoryHub.consolidate(facts: facts, aliases: characterAliases)
            facts = consolidated.facts
            updateChapter(n) { $0.summary = summary }
            outcome.applied += 1
        case .canonClassify(let items):
            // 归类：按标题精确匹配写类别；改名撞名则只改类别（保护既有文档）
            for item in items {
                outcome.total += 1
                guard let idx = canonSections.firstIndex(where: { $0.title == item.title }) else {
                    outcome.skipped.append("设定「\(item.title)」未找到（标题可能已改）")
                    continue
                }
                outcome.applied += 1
                canonSections[idx].category = CanonCategory.match(item.category).rawValue
                if let rename = item.rename, !rename.isEmpty, rename != item.title,
                   !canonSections.contains(where: { $0.title == rename }) {
                    // 删掉旧文件名的 md：否则下次保存的孤儿扫描会把它吃回来，
                    // 设定列表凭空多出一份旧副本。
                    deleteCanonMarkdown(title: item.title)
                    canonSections[idx].title = rename
                }
            }
        case .canon(let docs):
            // 设定是作者主权：同题不覆盖（作者可能手改过），只追加新题
            // 确定度用中文 rawValue 存储；AI 侧传英文键，这里映射
            let certaintyMap: [String: Certainty] = ["canon": .canon, "tentative": .tentative, "blank": .open, "open": .open]
            for d in docs {
                outcome.total += 1
                if canonSections.contains(where: { $0.title == d.title }) {
                    outcome.skipped.append("设定「\(d.title)」已存在（同题保护，未覆盖）")
                } else {
                    canonSections.append(CanonSection(title: d.title, content: d.content,
                                                      certainty: certaintyMap[d.certainty] ?? .tentative))
                    outcome.applied += 1
                }
            }
        case .clueFixes(let fixes):
            for f in fixes {
                outcome.total += 1
                if applyClueFix(f) {
                    outcome.applied += 1
                } else {
                    outcome.skipped.append("埋点修复 [\(f.clueID)]（\(f.kind)）未能应用（伏笔不存在或目标冲突）")
                }
            }
        case .outlineUpdates(let updates):
            for u in updates {
                outcome.total += 1
                if applyOutlineUpdate(u) {
                    outcome.applied += 1
                } else {
                    outcome.skipped.append("大纲更新 \(u.kind) 未能应用（目标事件/线不存在）")
                }
            }
        case .dossier(let d):
            var card = d
            if card.chapter == 0 { card.chapter = chapter ?? 0 }
            guard card.chapter > 0 else {
                outcome.skipped.append("档案卡缺少章节号")
                return outcome
            }
            upsertDossier(card)
            outcome.total += 1
            outcome.applied += 1
        case .report, .deslop, .memo:
            // 报告类提案（验证/去AI味/备忘）本就是「已阅」语义，无需入库——
            // 采纳动作对它们是有效决定，计 1 项成功（否则永远无法标记已采纳）
            if case .deslop(let report) = payload, report.targetDraftID == nil,
               !report.suggestions.isEmpty, report.suggestions.allSatisfy(\.applied) {
                // 全部建议已应用到正文 → 生命周期推进到「已润色」
                updateChapter(report.chapter) {
                    // 逐条采纳会先把正文改动降级为「写作中」，这里一并推进到已润色
                    if $0.status == .checked || $0.status == .written || $0.status == .writing {
                        $0.status = .polished
                    }
                }
            }
            outcome.total += 1
            outcome.applied += 1
        }
        return outcome
    }

    // MARK: - 埋点修复（台账修正；铁律：改账本，不改正文）

    /// 采纳一条伏笔修复方案。只动台账与动作日志——正文修改仍以作者定稿为准。
    /// 幂等：同一条 fix 采纳两次结果一致，所以收件箱里既可以整包采纳也可以逐条采纳。
    @discardableResult
    func applyClueFix(_ fix: ClueFix) -> Bool {
        // register 是「台账里没有这条」→ 新建；其余都必须先找到目标伏笔
        if fix.kind == .register {
            var c = Clue(id: nextClueID(), title: fix.newTitle ?? "未命名伏笔",
                         detail: fix.newDetail ?? fix.reason,
                         plantedChapter: fix.chapter, plantedQuote: fix.newQuote ?? "",
                         status: .planted, lastActionChapter: fix.chapter,
                         actions: [ClueActionLog(chapter: fix.chapter, kind: .plant, note: "连贯性审查补登记")])
            if clues.contains(where: { $0.title == c.title && $0.plantedChapter == c.plantedChapter }) { return false }
            c.targetPayoffChapter = fix.newTargetChapter
            if let raw = fix.newTimingRaw, let t = ClueTiming(rawValue: raw) { c.timing = t }
            clues.append(c)
            clues.sort { $0.id < $1.id }
            return true
        }
        guard let idx = clues.firstIndex(where: { $0.id == fix.clueID }) else { return false }
        // 幂等：逐条采纳过的修复，再点整包采纳时不能重复写动作日志
        let planned = Self.fixAction(fix, currentChapter: currentChapter)
        if clues[idx].actions.contains(where: { $0.chapter == planned.chapter && $0.note == planned.note }) {
            return true
        }
        var c = clues[idx]
        switch fix.kind {
        case .retarget:
            if let t = fix.newTargetChapter { c.targetPayoffChapter = t }
            if let raw = fix.newTimingRaw, let timing = ClueTiming(rawValue: raw) { c.timing = timing }
            // 改期要让过期告警停下来，否则作者改了期还继续被催
            c.lastActionChapter = max(c.lastActionChapter, currentChapter)
            c.actions.append(ClueActionLog(chapter: currentChapter, kind: .defer, note: "改期：" + fix.reason))
        case .resolve:
            c.status = .resolved
            c.lastActionChapter = max(c.lastActionChapter, fix.chapter)
            c.actions.append(ClueActionLog(chapter: fix.chapter, kind: .resolve, note: fix.reason))
            if c.targetPayoffChapter == nil { c.targetPayoffChapter = fix.chapter }
        case .defer:
            c.status = .deferred
            c.actions.append(ClueActionLog(chapter: currentChapter, kind: .defer, note: fix.reason))
        case .abandon:
            c.status = .abandoned
            c.actions.append(ClueActionLog(chapter: currentChapter, kind: .defer, note: "放弃：" + fix.reason))
        case .requote:
            // 种下原文是兑现时的对照物，写错了就等于账对不上；只在拿到真实片段时替换
            if let q = fix.newQuote, !q.isEmpty { c.plantedQuote = q }
        case .replant:
            // 台账说埋了、正文找不到：作者选择补写。这里只记意图，不动 lastActionChapter——
            // 逾期告警要一直响到正文真的补上为止，否则账就又烂回去了。
            c.status = .planted
            c.actions.append(ClueActionLog(chapter: fix.chapter, kind: .plant,
                                           note: "作者确认补埋（正文待补写）：" + fix.reason))
        case .register:
            break
        }
        clues[idx] = c
        return true
    }

    /// 与 applyClueFix 的动作日志一一对应，用于幂等判重
    private static func fixAction(_ fix: ClueFix, currentChapter: Int) -> (chapter: Int, note: String) {
        switch fix.kind {
        case .retarget: return (currentChapter, "改期：" + fix.reason)
        case .resolve: return (fix.chapter, fix.reason)
        case .defer: return (currentChapter, fix.reason)
        case .abandon: return (currentChapter, "放弃：" + fix.reason)
        case .replant: return (fix.chapter, "作者确认补埋（正文待补写）：" + fix.reason)
        case .requote, .register: return (-1, "")
        }
    }

    // MARK: - 大纲同步落库

    /// 采纳一条大纲更新。事件不删除——取消用 dropped 标记，保留「曾经计划过什么」的痕迹。
    @discardableResult
    func applyOutlineUpdate(_ u: OutlineUpdate) -> Bool {
        let now = Date()
        switch u.kind {
        case .eventHappened, .eventMoved, .eventRevealed, .eventDropped:
            guard let eid = u.eventID, let idx = timelineEvents.firstIndex(where: { $0.id == eid }) else { return false }
            var e = timelineEvents[idx]
            switch u.kind {
            case .eventHappened:
                e.happened = true
                if e.actualChapter == nil { e.actualChapter = u.newChapter ?? e.chapter }
            case .eventMoved:
                // 「改期」是把计划挪到新章，不是声称它已经发生。
                // 旧实现置 happened=true 却不改 chapter，导致事件既显示旧章又退出后续对账。
                if let dest = u.newChapter { e.chapter = dest }
                e.happened = false
                e.actualChapter = nil
                e.dropped = false
            case .eventRevealed:
                e.revealed = true
                if e.revealChapter == nil { e.revealChapter = u.newChapter ?? e.actualChapter ?? e.chapter }
            case .eventDropped:
                e.dropped = true
            default:
                break
            }
            e.syncNote = u.reason
            e.syncedAt = now
            timelineEvents[idx] = e
        case .storylineStatus:
            guard let lid = u.storylineID, let idx = storylines.firstIndex(where: { $0.id == lid }) else { return false }
            guard let status = ActiveStatus(rawValue: u.newStatusRaw ?? "") else { return false }
            storylines[idx].status = status
        case .stageAdjust:
            guard let sid = u.stageID, let idx = stages.firstIndex(where: { $0.id == sid }) else { return false }
            if let end = u.newChapter, end >= stages[idx].chapterStart { stages[idx].chapterEnd = end }
        }
        return true
    }

    // MARK: - 流水线草稿

    /// 某章最新的（未拒绝）草稿提案
    func latestDraftProposal(for n: Int) -> AIProposal? {
        proposals.first { p in
            guard p.chapterNumber == n, p.status == .pending else { return false }
            if case .draft = p.payload { return true }
            return false
        }
    }

    /// 某章最近一份可继续修订的草稿提案（已采纳/待审；**排除已拒绝**）。
    /// 修订历史的价值不随采纳消失——采纳后继续修订时用它恢复 feedbackHistory；
    /// 但被拒绝的稿子不能换个版本号又回来。
    func latestAnyDraftProposal(for n: Int) -> AIProposal? {
        proposals.first { p in
            guard p.chapterNumber == n, p.status != .rejected else { return false }
            if case .draft = p.payload { return true }
            return false
        }
    }

    /// 修订完成后把意见历史与主线写进新草稿提案（工具 schema 不携带这两项）
    func updateDraftMetadata(proposalID: UUID, mainline: String, feedbackHistory: [DraftFeedback]) {
        guard let idx = proposals.firstIndex(where: { $0.id == proposalID }),
              case .draft(var d) = proposals[idx].payload else { return }
        d.mainline = mainline
        d.feedbackHistory = feedbackHistory
        proposals[idx].payload = .draft(d)
        saveSoon()
    }

    func draftPayload(of p: AIProposal) -> ChapterDraft? {
        if case .draft(let d) = p.payload { return d }
        return nil
    }

    // MARK: - 去AI味 / 验证报告的可变入口

    func mutateDeslopReport(proposalID: UUID, _ mutate: (inout DeslopReport) -> Void) {
        guard let idx = proposals.firstIndex(where: { $0.id == proposalID }),
              case .deslop(var report) = proposals[idx].payload else { return }
        mutate(&report)
        proposals[idx].payload = .deslop(report)
        saveSoon()
    }

    @discardableResult
    func markDeslopSuggestionApplied(proposalID: UUID, suggestionID: UUID) -> Bool {
        var found = false
        mutateDeslopReport(proposalID: proposalID) { report in
            guard let i = report.suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
            report.suggestions[i].applied = true
            found = true
        }
        return found
    }

    func mutateValidationReport(proposalID: UUID, _ mutate: (inout ValidationReport) -> Void) {
        guard let idx = proposals.firstIndex(where: { $0.id == proposalID }),
              case .report(var report) = proposals[idx].payload else { return }
        mutate(&report)
        proposals[idx].payload = .report(report)
        saveSoon()
    }

    /// 草稿版本号 = 已有草稿提案数 + 1
    func nextDraftVersion(for n: Int) -> Int {
        proposals.filter { p in
            guard p.chapterNumber == n else { return false }
            if case .draft = p.payload { return true }
            return false
        }.count + 1
    }

    // MARK: - 版本快照（InkOS：改动前先归档，任何修订都可回滚）

    /// 把某章当前正文存为快照，返回快照文件名
    @discardableResult
    func snapshotProse(chapter n: Int, tag: String) -> String? {
        guard let ch = chapter(n), !ch.prose.isEmpty else { return nil }
        let dir = ProjectLayout.chapterDir(rootURL, number: n).appendingPathComponent("snapshots", isDirectory: true)
        let stamp = Self.fileStamp()
        // 同名（同秒 + 固定 tag）会静默覆盖旧备份：叠加序号保证每次都留住
        var name = "\(stamp)-\(tag).md"
        var seq = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(stamp)-\(tag)-\(seq).md"
            seq += 1
        }
        let proseURL = dir.appendingPathComponent(name)
        let metaURL = dir.appendingPathComponent(name + ".meta.json")
        // 正文与 meta 一起快照：只回滚正文会留下「旧稿 + 新状态/新骨架」的组合
        let meta = ChapterMeta(id: ch.id, number: ch.number, title: ch.title, status: ch.status,
                               skeleton: ch.skeleton, summary: ch.summary, notes: ch.notes,
                               directive: ch.directive, cachedWords: ch.cachedWords, updatedAt: ch.updatedAt)
        do {
            try Disk.write(Data(ch.prose.utf8), to: proseURL)
            try Disk.writeJSON(meta, to: metaURL)
            Self.pruneSnapshots(in: dir, keep: 100)
            return name
        } catch {
            try? FileManager.default.removeItem(at: proseURL)
            try? FileManager.default.removeItem(at: metaURL)
            lastSaveError = "快照写入失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 每章最多保留最近 100 个快照（含 meta sidecar），避免自动快照无限增长
    private static func pruneSnapshots(in dir: URL, keep: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let proseFiles = files.filter { $0.pathExtension == "md" }
        guard proseFiles.count > keep else { return }
        let sorted = proseFiles.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if da != db { return da > db }
            return a.lastPathComponent < b.lastPathComponent
        }
        for old in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: old.appendingPathExtension("meta.json"))
        }
    }

    func snapshots(chapter n: Int) -> [(name: String, text: String)] {
        let dir = ProjectLayout.chapterDir(rootURL, number: n).appendingPathComponent("snapshots", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let sorted = files.filter { $0.pathExtension == "md" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if da != db { return da > db }
            // 同秒快照：带 -2 后缀的是后建的；按名字降序会让基名排前面，这里改成升序兜底
            return a.lastPathComponent < b.lastPathComponent
        }
        return sorted.map { ($0.lastPathComponent, Disk.readText($0)) }
    }

    /// 用快照回滚某章正文。返回 false = 快照读不到/为空，界面不能再报"已回滚"。
    @discardableResult
    func restoreSnapshot(chapter n: Int, name: String) -> Bool {
        let url = ProjectLayout.chapterDir(rootURL, number: n).appendingPathComponent("snapshots").appendingPathComponent(name)
        let text = Disk.readText(url)
        guard !text.isEmpty else {
            lastSaveError = "回滚失败：快照「\(name)」读不到或为空（文件可能已被移动）。"
            return false
        }
        guard snapshotProse(chapter: n, tag: "回滚前") != nil || chapter(n)?.prose.isEmpty == true else {
            lastSaveError = "回滚中止：当前稿的快照写入失败（检查磁盘/权限）。"
            return false
        }
        // 外部写过的文件：让写签名失效，强制本次回滚内容真正落盘
        Disk.invalidateSignature(ProjectLayout.proseFile(rootURL, number: n))
        let metaURL = ProjectLayout.chapterDir(rootURL, number: n)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(name + ".meta.json")
        let meta = try? Disk.readJSON(ChapterMeta.self, from: metaURL)
        // 先回正文（会自动降级状态），再用快照 meta 覆盖状态/骨架/摘要：
        // 顺序反了会被 updateChapter 的「改正文即降级」规则把快照状态冲掉。
        updateChapter(n) { $0.prose = text }
        if let meta {
            updateChapter(n, countWords: false) { ch in
                ch.title = meta.title
                ch.status = meta.status
                ch.skeleton = meta.skeleton
                ch.summary = meta.summary
                ch.notes = meta.notes
                ch.directive = meta.directive
            }
        }
        return true
    }

    static func fileStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// 写入/更新一张章档案卡（记忆提取采纳时调用）
    func upsertDossier(_ dossier: ChapterDossier) {
        if let idx = dossiers.firstIndex(where: { $0.chapter == dossier.chapter }) {
            dossiers[idx] = dossier
        } else {
            dossiers.append(dossier)
        }
        dossiers.sort { $0.chapter < $1.chapter }
        saveSoon()
    }

    /// 采用/更新本书封面（作者显式动作；内容变了 Disk 签名自然失效）
    func setCoverSVG(_ svg: String) {
        coverSVG = svg
        saveSoon()
    }

    /// 删除设定的磁盘 md（删除/改名时调用，避免孤儿导入把它复活成新节）
    func deleteCanonMarkdown(title: String) {
        let dir = ProjectLayout.canonDir(rootURL)
        for suffix in ["", "-x", "-x-x"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(ProjectLayout.safeFileName(title) + suffix + ".md"))
        }
    }

    /// 作者手动登记伏笔动作（写完一章后的对账）
    func logClueAction(clueID: String, chapter: Int, kind: ClueActionKind, note: String = "") {
        guard let idx = clues.firstIndex(where: { $0.id == clueID }) else { return }
        clues[idx].actions.append(ClueActionLog(chapter: chapter, kind: kind, note: note))
        clues[idx].lastActionChapter = chapter
        switch kind {
        case .plant: clues[idx].status = .planted
        case .develop: if clues[idx].status == .planted { clues[idx].status = .developing }
        case .reveal, .resolve: clues[idx].status = .resolved
        case .`defer`: clues[idx].status = .deferred
        }
        saveSoon()
    }

    // MARK: - Checkpoint（PIAgent 会话状态持久化）

    func saveCheckpoint(_ data: Data, name: String) {
        try? Disk.write(data, to: ProjectLayout.checkpointsDir(rootURL).appendingPathComponent(name))
    }

    func loadCheckpoint(name: String) -> Data? {
        try? Data(contentsOf: ProjectLayout.checkpointsDir(rootURL).appendingPathComponent(name))
    }
}

struct MemoryFile: Codable {
    var facts: [MemoryFact] = []
    var aliases: [CharacterAlias] = []
    /// 已裁决"保留两条"的矛盾键（不重复提醒）
    var dismissedConflicts: [String]? = []
}

extension MemoryFile {
    private enum Keys: String, CodingKey { case facts, aliases, dismissedConflicts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        facts = try c.decodeIfPresent([MemoryFact].self, forKey: .facts) ?? []
        aliases = try c.decodeIfPresent([CharacterAlias].self, forKey: .aliases) ?? []
        dismissedConflicts = try c.decodeIfPresent([String].self, forKey: .dismissedConflicts)
    }
}
