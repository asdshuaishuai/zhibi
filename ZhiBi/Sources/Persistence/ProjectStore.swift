import Foundation
import Combine

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
    /// 最近一次保存失败原因（磁盘满/权限等）——UI 状态条展示
    @Published var lastSaveError: String?
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
        var chapters: [Chapter]
        var quarantineNotes: [String]

        static func capture(rootURL: URL) throws -> LoadSnapshot {
            let project = try Disk.readJSON(NovelProject.self, from: ProjectLayout.projectFile(rootURL))
        let coverSVG: String? = {
            let f = rootURL.appendingPathComponent("cover.svg")
            guard FileManager.default.fileExists(atPath: f.path) else { return nil }
            return try? String(contentsOf: f, encoding: .utf8)
        }()
            let sectionsFile = ProjectLayout.canonDir(rootURL).appendingPathComponent("sections.json")
            let canon: [CanonSection]
            if FileManager.default.fileExists(atPath: sectionsFile.path) {
                canon = (try? Disk.readJSON([CanonSection].self, from: sectionsFile)) ?? []
            } else {
                canon = ProjectStore.loadCanonFromDisk(rootURL: rootURL)
            }
            let storylines = (try? Disk.readJSON([Storyline].self, from: ProjectLayout.storylinesFile(rootURL))) ?? []
            let timelineEvents = (try? Disk.readJSON([TimelineEvent].self, from: ProjectLayout.eventsFile(rootURL))) ?? []
            let stages = (try? Disk.readJSON([Stage].self, from: ProjectLayout.stagesFile(rootURL))) ?? []
            let clues = (try? Disk.readJSON([Clue].self, from: ProjectLayout.cluesFile(rootURL))) ?? []
            let memory = try? Disk.readJSON(MemoryFile.self, from: ProjectLayout.memoryFile(rootURL))
            let dossiers = (try? Disk.readJSON([ChapterDossier].self, from: ProjectLayout.dossiersFile(rootURL))) ?? []
            let pending = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsFile(rootURL))) ?? []
            let archived = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsArchiveFile(rootURL))) ?? []
            let proposals = (pending + archived).sorted { $0.createdAt > $1.createdAt }

            var loaded: [Chapter] = []
            var quarantineNotes: [String] = []
            let fm = FileManager.default
            if let dirs = try? fm.contentsOfDirectory(at: ProjectLayout.chaptersDir(rootURL), includingPropertiesForKeys: nil) {
                for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("ch-") {
                    guard let num = Int(dir.lastPathComponent.dropFirst(3)) else { continue }
                    let proseFile = ProjectLayout.proseFile(rootURL, number: num)
                    var ch = ProjectStore.loadChapterMeta(rootURL: rootURL, number: num,
                                                         proseFileMissing: !fm.fileExists(atPath: proseFile.path))
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
                                timelineEvents: timelineEvents, stages: stages, clues: clues, memory: memory,
                                proposals: proposals, dossiers: dossiers, chapters: loaded, quarantineNotes: quarantineNotes)
        }
    }

    /// 主线程应用快照（唯一的 store 变更点）
    @discardableResult
    func applySnapshot(_ snapshot: LoadSnapshot) throws -> Bool {
        self.project = snapshot.project
        self.coverSVG = snapshot.coverSVG
        self.canonSections = snapshot.canonSections
        self.storylines = snapshot.storylines
        self.timelineEvents = snapshot.timelineEvents
        self.stages = snapshot.stages
        self.clues = snapshot.clues
        self.facts = snapshot.memory?.facts ?? []
        self.characterAliases = snapshot.memory?.aliases ?? []
        self.dismissedConflicts = snapshot.memory?.dismissedConflicts ?? []
        self.proposals = snapshot.proposals
        self.dossiers = snapshot.dossiers
        self.chapters = snapshot.chapters.sorted { $0.number < $1.number }
        dirtyChapters.removeAll()
        if !snapshot.quarantineNotes.isEmpty {
            lastSaveError = snapshot.quarantineNotes.joined(separator: " ")
            // 隔离过的正文：写签名失效，强制下次保存真正落盘
            for ch in snapshot.chapters where ch.prose.isEmpty {
                Disk.invalidateSignature(ProjectLayout.proseFile(rootURL, number: ch.number))
            }
        }
        return true
    }

    func loadSync() throws {
        let sectionsFile = ProjectLayout.canonDir(rootURL).appendingPathComponent("sections.json")
        if FileManager.default.fileExists(atPath: sectionsFile.path) {
            canonSections = (try? Disk.readJSON([CanonSection].self, from: sectionsFile)) ?? []
        } else {
            canonSections = Self.loadCanonFromDisk(rootURL: rootURL)
        }
        storylines = (try? Disk.readJSON([Storyline].self, from: ProjectLayout.storylinesFile(rootURL))) ?? []
        timelineEvents = (try? Disk.readJSON([TimelineEvent].self, from: ProjectLayout.eventsFile(rootURL))) ?? []
        stages = (try? Disk.readJSON([Stage].self, from: ProjectLayout.stagesFile(rootURL))) ?? []
        clues = (try? Disk.readJSON([Clue].self, from: ProjectLayout.cluesFile(rootURL))) ?? []
        let mem = try? Disk.readJSON(MemoryFile.self, from: ProjectLayout.memoryFile(rootURL))
        facts = mem?.facts ?? []
        characterAliases = mem?.aliases ?? []
        dismissedConflicts = mem?.dismissedConflicts ?? []
        let pendingLoaded = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsFile(rootURL))) ?? []
        let archivedLoaded = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsArchiveFile(rootURL))) ?? []
        proposals = (pendingLoaded + archivedLoaded).sorted { $0.createdAt > $1.createdAt }

        var loaded: [Chapter] = []
        var quarantineNotes: [String] = []
        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: ProjectLayout.chaptersDir(rootURL), includingPropertiesForKeys: nil) {
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("ch-") {
                guard let num = Int(dir.lastPathComponent.dropFirst(3)) else { continue }
                let proseFile = ProjectLayout.proseFile(rootURL, number: num)
                var ch = Self.loadChapterMeta(rootURL: rootURL, number: num,
                                              proseFileMissing: !fm.fileExists(atPath: proseFile.path))
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
        if !quarantineNotes.isEmpty {
            lastSaveError = quarantineNotes.joined(separator: " ")
        }
        loaded.sort { $0.number < $1.number }
        chapters = loaded
        dirtyChapters.removeAll()
    }

    /// canon 目录下的人写 markdown（人可手改的设定文件）
    nonisolated private static func loadCanonFromDisk(rootURL: URL) -> [CanonSection] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: ProjectLayout.canonDir(rootURL), includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { CanonSection(title: $0.deletingPathExtension().lastPathComponent, content: Disk.readText($0)) }
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
            var cachedWords: Int?
            var updatedAt: Date
        }
        for ch in chapters where dirtyChapters.contains(ch.number) {
            let meta = MetaChapter(id: ch.id, number: ch.number, title: ch.title, status: ch.status,
                                   skeleton: ch.skeleton, summary: ch.summary, notes: ch.notes,
                                   cachedWords: ch.cachedWords, updatedAt: ch.updatedAt)
            try Disk.writeJSON(meta, to: Self.chapterMetaURL(rootURL, ch.number))
            try Disk.write(Data(ch.prose.utf8), to: ProjectLayout.proseFile(rootURL, number: ch.number))
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
        var nameByTitle: [String: String] = [:]
        for section in canonSections {
            var name = ProjectLayout.safeFileName(section.title)
            while writtenNames.contains(name + ".md") { name += "-x" }
            writtenNames.insert(name + ".md")
            nameByTitle[section.title] = name
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
                    nameByTitle[title] = name
                }
            }
        }
        try Disk.writeJSON(canonSections, to: canonDir.appendingPathComponent("sections.json"))
        // 每节 md：内容没变就跳过写（省 iCloud 上传/主线程）；单节失败不中断保存
        var canonWriteFailed = false
        for section in canonSections {
            let name = nameByTitle[section.title] ?? ProjectLayout.safeFileName(section.title)
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
        if !archivedProposals.isEmpty {
            try Disk.writeJSON(archivedProposals, to: ProjectLayout.proposalsArchiveFile(rootURL))
        }
        try Disk.writeJSON(dossiers, to: ProjectLayout.dossiersFile(rootURL))
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
    nonisolated static func loadChapterMeta(rootURL: URL, number n: Int, proseFileMissing: Bool) -> Chapter {
        let url = chapterMetaURL(rootURL, n)
        guard let meta = try? Disk.readJSON(ChapterMeta.self, from: url) else {
            // meta.json 真的解不出来（更老的格式）：退回 Chapter，至少把能认出来的字段救回来
            return (try? Disk.readJSON(Chapter.self, from: url)) ?? Chapter(number: n)
        }
        var ch = Chapter(number: n)
        ch.id = meta.id
        ch.title = meta.title
        ch.status = meta.status
        ch.skeleton = meta.skeleton
        ch.summary = meta.summary
        ch.notes = meta.notes
        ch.cachedWords = meta.cachedWords
        ch.updatedAt = meta.updatedAt
        if proseFileMissing, let legacy = try? Disk.readJSON(LegacyMetaProse.self, from: url) {
            ch.prose = legacy.prose ?? ""
        }
        return ch
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
        mutate(&chapters[idx])
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
        chapters.removeAll { $0.number == number }
        timelineEvents.removeAll { $0.chapter == number }
        dirtyChapters.remove(number)
        Self.moveToTrash(ProjectLayout.chapterDir(rootURL, number: number))
        saveSoon()
    }

    /// 删除走废纸篓（可恢复）；废纸篓失败才真删
    static func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var currentChapter: Int {
        let drafted = chapters.filter { $0.status != .empty && $0.status != .skeletoned }.map(\.number).max() ?? 0
        return drafted + 1
    }

    // MARK: - 伏笔

    func nextClueID() -> String {
        let maxN = clues.compactMap { c -> Int? in
            guard c.id.hasPrefix("F"), let n = Int(c.id.dropFirst()) else { return nil }
            return n
        }.max() ?? 0
        return String(format: "F%02d", maxN + 1)
    }

    func applyClueActions(chapter: Int, touches: [ClueTouch]) {
        for touch in touches {
            guard let idx = clues.firstIndex(where: { $0.id == touch.clueID }) else { continue }
            clues[idx].lastActionChapter = chapter
            clues[idx].actions.append(ClueActionLog(chapter: chapter, kind: touch.action, note: touch.requirement))
            switch touch.action {
            case .plant: clues[idx].status = .planted
            case .develop: if clues[idx].status == .planted { clues[idx].status = .developing }
            case .reveal, .resolve: clues[idx].status = .resolved
            case .`defer`: clues[idx].status = .deferred
            }
        }
        saveSoon()
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

    func acceptProposal(_ id: UUID) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        guard proposals[idx].status == .pending else { return }  // 防重复采纳覆盖手改
        let p = proposals[idx]
        let outcome = applyPayloadDetailed(p.payload, chapter: p.chapterNumber)
        guard outcome.applied > 0 else {
            // 完全没入库：保持 pending（否则提案从待审列表消失且永不可再采纳）
            lastAcceptIssues = "未采纳：\(outcome.summary)"
            return
        }
        guard outcome.isFullSuccess else {
            // 全无或部分入库：部分成功时也保持 pending——已入库的部分有幂等保护
            // （事件/故事线按 id 去重、设定同题保护、伏笔同 id 合并），重试不会重复
            lastAcceptIssues = "部分采纳：\(outcome.summary)。提案保持待审——修好未入库项后可再点采纳（已入库项不会重复）。"
            return
        }
        lastAcceptIssues = nil
        proposals[idx].status = .accepted
        proposals[idx].decidedAt = Date()
        saveSoon()
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
            for e in events {
                outcome.total += 1
                if timelineEvents.contains(where: { $0.id == e.id && $0.chapter == e.chapter }) {
                    outcome.skipped.append("事件 [\(e.id)]@第\(e.chapter)章 已存在")
                } else {
                    timelineEvents.append(e)
                    outcome.applied += 1
                }
            }
            timelineEvents.sort { ($0.chapter, $0.id) < ($1.chapter, $1.id) }
        case .storylines(let lines):
            for l in lines {
                outcome.total += 1
                if storylines.contains(where: { $0.id == l.id }) {
                    outcome.skipped.append("故事线 [\(l.id)] 已存在（编号撞号）")
                } else {
                    storylines.append(l)
                    outcome.applied += 1
                }
            }
        case .clues(let newClues):
            for c in newClues {
                outcome.total += 1
                if let idx = clues.firstIndex(where: { $0.id == c.id }) {
                    clues[idx] = c
                } else {
                    clues.append(c)
                }
                outcome.applied += 1
            }
            clues.sort { $0.id < $1.id }
        case .skeleton(let sk):
            guard let n = chapter else {
                outcome.skipped.append("提案缺少章节号")
                return outcome
            }
            updateChapter(n) { $0.skeleton = sk; if $0.status == .empty { $0.status = .skeletoned } }
            // 骨架里的伏笔触点合同落到台账（AI 骨架声明 F03 本章揭示 → 台账记一笔）
            applyClueActions(chapter: n, touches: sk.clueTouches)
            outcome.total += 1
            outcome.applied += 1
        case .draft(let draft):
            // 作者采纳草稿才走到这里；覆盖前自动快照，快照失败则中止采纳（旧稿保住，提案保持待审）
            guard let n = chapter else {
                outcome.skipped.append("提案缺少章节号")
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
                if $0.status == .empty || $0.status == .skeletoned || $0.status == .writing { $0.status = .written }
            }
            outcome.applied += 1
        case .memoryPack(let newFacts, let summary, let newClues):
            // 章节 guard 前置：避免半途 append 后失败导致重复追加
            guard let n = chapter else {
                outcome.skipped.append("提案缺少章节号")
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
                    if authorTouched {
                        merged.status = existing.status
                        merged.actions = existing.actions
                        merged.lastActionChapter = existing.lastActionChapter
                    }
                    clues[idx] = merged
                } else {
                    var cand = c
                    if cand.id.isEmpty { cand.id = nextClueID() }
                    clues.append(cand)
                }
            }
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
            outcome.total += 1
            outcome.applied += 1
        }
        return outcome
    }

    // MARK: - 埋点修复（台账修正；铁律：改账本，不改正文）

    /// 采纳一条伏笔修复方案。只动台账与动作日志——正文永远由作者亲笔补写。
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
                e.happened = true
                e.actualChapter = u.newChapter ?? e.actualChapter
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

    /// 某章最近一份**任意状态**的草稿提案（含已采纳/已拒绝）。
    /// 修订历史的价值不随采纳消失——采纳后继续修订时用它恢复 feedbackHistory。
    func latestAnyDraftProposal(for n: Int) -> AIProposal? {
        proposals.first { p in
            guard p.chapterNumber == n else { return false }
            if case .draft = p.payload { return true }
            return false
        }
    }

    func draftPayload(of p: AIProposal) -> ChapterDraft? {
        if case .draft(let d) = p.payload { return d }
        return nil
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
        do {
            try Disk.write(Data(ch.prose.utf8), to: dir.appendingPathComponent(name))
            return name
        } catch {
            lastSaveError = "快照写入失败：\(error.localizedDescription)"
            return nil
        }
    }

    func snapshots(chapter n: Int) -> [(name: String, text: String)] {
        let dir = ProjectLayout.chapterDir(rootURL, number: n).appendingPathComponent("snapshots", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { ($0.lastPathComponent, Disk.readText($0)) }
    }

    /// 用快照回滚某章正文
    func restoreSnapshot(chapter n: Int, name: String) {
        let url = ProjectLayout.chapterDir(rootURL, number: n).appendingPathComponent("snapshots").appendingPathComponent(name)
        let text = Disk.readText(url)
        guard !text.isEmpty else { return }
        _ = snapshotProse(chapter: n, tag: "回滚前")   // 回滚不毁当前稿
        // 外部写过的文件：让写签名失效，强制本次回滚内容真正落盘
        Disk.invalidateSignature(ProjectLayout.proseFile(rootURL, number: n))
        updateChapter(n) { $0.prose = text }
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
