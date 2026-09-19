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
        var canonSections: [CanonSection]
        var storylines: [Storyline]
        var timelineEvents: [TimelineEvent]
        var stages: [Stage]
        var clues: [Clue]
        var memory: MemoryFile?
        var proposals: [AIProposal]
        var chapters: [Chapter]
        var quarantineNotes: [String]

        static func capture(rootURL: URL) throws -> LoadSnapshot {
            let project = try Disk.readJSON(NovelProject.self, from: ProjectLayout.projectFile(rootURL))
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
            let proposals = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsFile(rootURL))) ?? []

            var loaded: [Chapter] = []
            var quarantineNotes: [String] = []
            let fm = FileManager.default
            if let dirs = try? fm.contentsOfDirectory(at: ProjectLayout.chaptersDir(rootURL), includingPropertiesForKeys: nil) {
                for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("ch-") {
                    guard let num = Int(dir.lastPathComponent.dropFirst(3)) else { continue }
                    var ch = (try? Disk.readJSON(Chapter.self, from: ProjectStore.chapterMetaURL(rootURL, num))) ?? Chapter(number: num)
                    // 正文读不了（非 UTF-8 等）：原稿隔离为 .corrupt，绝不静默清空后覆盖
                    let proseFile = ProjectLayout.proseFile(rootURL, number: num)
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
            return LoadSnapshot(project: project, canonSections: canon, storylines: storylines,
                                timelineEvents: timelineEvents, stages: stages, clues: clues, memory: memory,
                                proposals: proposals, chapters: loaded, quarantineNotes: quarantineNotes)
        }
    }

    /// 主线程应用快照（唯一的 store 变更点）
    @discardableResult
    func applySnapshot(_ snapshot: LoadSnapshot) throws -> Bool {
        self.project = snapshot.project
        self.canonSections = snapshot.canonSections
        self.storylines = snapshot.storylines
        self.timelineEvents = snapshot.timelineEvents
        self.stages = snapshot.stages
        self.clues = snapshot.clues
        self.facts = snapshot.memory?.facts ?? []
        self.characterAliases = snapshot.memory?.aliases ?? []
        self.dismissedConflicts = snapshot.memory?.dismissedConflicts ?? []
        self.proposals = snapshot.proposals
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
        proposals = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsFile(rootURL))) ?? []

        var loaded: [Chapter] = []
        var quarantineNotes: [String] = []
        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: ProjectLayout.chaptersDir(rootURL), includingPropertiesForKeys: nil) {
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("ch-") {
                guard let num = Int(dir.lastPathComponent.dropFirst(3)) else { continue }
                var ch = (try? Disk.readJSON(Chapter.self, from: ProjectStore.chapterMetaURL(rootURL, num))) ?? Chapter(number: num)
                // 正文读不了（非 UTF-8 等）：原稿隔离为 .corrupt，绝不静默清空后覆盖
                let proseFile = ProjectLayout.proseFile(rootURL, number: num)
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
        try Disk.writeJSON(proposals, to: ProjectLayout.proposalsFile(rootURL))
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

    func acceptProposal(_ id: UUID) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        guard proposals[idx].status == .pending else { return }  // 防重复采纳覆盖手改
        let p = proposals[idx]
        // 入库失败（快照写不进/章节丢失）时保持 pending——否则提案会从待审列表消失且永不可再采纳
        guard applyPayload(p.payload, chapter: p.chapterNumber) else { return }
        proposals[idx].status = .accepted
        proposals[idx].decidedAt = Date()
        saveSoon()
    }

    func rejectProposal(_ id: UUID) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[idx].status = .rejected
        proposals[idx].decidedAt = Date()
        saveSoon()
    }

    /// 误拒绝恢复：重新待审（拒绝是不可逆操作里唯一必须给撤销口子的）
    func reopenProposal(_ id: UUID) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[idx].status = .pending
        proposals[idx].decidedAt = nil
        saveSoon()
    }

    /// 采纳提案 = 把 payload 写入权威状态（宿主裁决的唯一入口）
    /// 返回 false = 未入库（调用方应保持提案 pending 而不是标记已采纳）
    @discardableResult
    func applyPayload(_ payload: ProposalPayload, chapter: Int?) -> Bool {
        switch payload {
        case .outlineEvents(let events):
            for e in events {
                if !timelineEvents.contains(where: { $0.id == e.id && $0.chapter == e.chapter }) {
                    timelineEvents.append(e)
                }
            }
            timelineEvents.sort { ($0.chapter, $0.id) < ($1.chapter, $1.id) }
        case .storylines(let lines):
            for l in lines where !storylines.contains(where: { $0.id == l.id }) {
                storylines.append(l)
            }
        case .clues(let newClues):
            for c in newClues {
                if let idx = clues.firstIndex(where: { $0.id == c.id }) {
                    clues[idx] = c
                } else {
                    clues.append(c)
                }
            }
            clues.sort { $0.id < $1.id }
        case .skeleton(let sk):
            guard let n = chapter else { return false }
            updateChapter(n) { $0.skeleton = sk; if $0.status == .empty { $0.status = .skeletoned } }
            // 骨架里的伏笔触点合同落到台账（AI 骨架声明 F03 本章揭示 → 台账记一笔）
            applyClueActions(chapter: n, touches: sk.clueTouches)
        case .draft(let draft):
            // 作者采纳草稿才走到这里；覆盖前自动快照，快照失败则中止采纳（旧稿保住，提案保持待审）
            guard let n = chapter else { return false }
            if let existing = self.chapter(n), !existing.prose.isEmpty {
                guard snapshotProse(chapter: n, tag: "采纳草稿前") != nil else {
                    lastSaveError = "采纳中止：快照写入失败（检查磁盘/权限），草稿仍在收件箱"
                    return false
                }
            }
            updateChapter(n) {
                $0.prose = draft.text
                if $0.status == .empty || $0.status == .skeletoned || $0.status == .writing { $0.status = .written }
            }
        case .memoryPack(let newFacts, let summary, let newClues):
            // 章节 guard 前置：避免半途 append 后失败导致重复追加
            guard let n = chapter else { return false }
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
        case .canon(let docs):
            // 设定是作者主权：同题不覆盖（作者可能手改过），只追加新题
            // 确定度用中文 rawValue 存储；AI 侧传英文键，这里映射
            let certaintyMap: [String: Certainty] = ["canon": .canon, "tentative": .tentative, "blank": .open, "open": .open]
            for d in docs where !canonSections.contains(where: { $0.title == d.title }) {
                canonSections.append(CanonSection(title: d.title, content: d.content,
                                                  certainty: certaintyMap[d.certainty] ?? .tentative))
            }
        case .report, .deslop, .memo:
            break // 报告类提案已展示在收件箱，无需入库
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
