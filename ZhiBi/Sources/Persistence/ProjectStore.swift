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

    func load() throws {
        project = try Disk.readJSON(NovelProject.self, from: ProjectLayout.projectFile(rootURL))
        let sectionsFile = ProjectLayout.canonDir(rootURL).appendingPathComponent("sections.json")
        if FileManager.default.fileExists(atPath: sectionsFile.path) {
            canonSections = (try? Disk.readJSON([CanonSection].self, from: sectionsFile)) ?? []
        } else {
            canonSections = loadCanonFromDisk()
        }
        storylines = (try? Disk.readJSON([Storyline].self, from: ProjectLayout.outlineFile(rootURL).appendingPathComponent("storylines.json"))) ?? []
        timelineEvents = (try? Disk.readJSON([TimelineEvent].self, from: ProjectLayout.outlineFile(rootURL).appendingPathComponent("events.json"))) ?? []
        stages = (try? Disk.readJSON([Stage].self, from: ProjectLayout.outlineFile(rootURL).appendingPathComponent("stages.json"))) ?? []
        clues = (try? Disk.readJSON([Clue].self, from: ProjectLayout.cluesFile(rootURL))) ?? []
        let mem = try? Disk.readJSON(MemoryFile.self, from: ProjectLayout.memoryFile(rootURL))
        facts = mem?.facts ?? []
        characterAliases = mem?.aliases ?? []
        dismissedConflicts = mem?.dismissedConflicts ?? []
        proposals = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsFile(rootURL))) ?? []

        var loaded: [Chapter] = []
        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: ProjectLayout.chaptersDir(rootURL), includingPropertiesForKeys: nil) {
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("ch-") {
                guard let num = Int(dir.lastPathComponent.dropFirst(3)) else { continue }
                var ch = (try? Disk.readJSON(Chapter.self, from: chapterMetaURL(num))) ?? Chapter(number: num)
                ch.prose = Disk.readText(ProjectLayout.proseFile(rootURL, number: num))
                loaded.append(ch)
            }
        }
        loaded.sort { $0.number < $1.number }
        chapters = loaded
        dirtyChapters.removeAll()
    }

    /// canon 目录下的人写 markdown（人可手改的设定文件）
    private func loadCanonFromDisk() -> [CanonSection] {
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
        for ch in chapters where dirtyChapters.contains(ch.number) {
            try Disk.writeJSON(ch, to: chapterMetaURL(ch.number))
            try Disk.write(Data(ch.prose.utf8), to: ProjectLayout.proseFile(rootURL, number: ch.number))
        }
        try Disk.writeJSON(project, to: ProjectLayout.projectFile(rootURL))
        try Disk.writeJSON(canonSections, to: ProjectLayout.canonDir(rootURL).appendingPathComponent("sections.json"))
        // canon 每节同步导出为可手改的 md（派生视图）；文件名安全化，并清理已删除节的孤儿文件
        let liveNames = Set(canonSections.map { ProjectLayout.safeFileName($0.title) + ".md" })
        let canonDir = ProjectLayout.canonDir(rootURL)
        if let existing = try? FileManager.default.contentsOfDirectory(at: canonDir, includingPropertiesForKeys: nil) {
            for f in existing where f.pathExtension == "md" && !liveNames.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            }
        }
        for section in canonSections {
            try Disk.write(Data(section.content.utf8), to: canonDir.appendingPathComponent(ProjectLayout.safeFileName(section.title) + ".md"))
        }
        let outlineDir = ProjectLayout.outlineFile(rootURL).deletingLastPathComponent()
        try Disk.writeJSON(storylines, to: outlineDir.appendingPathComponent("storylines.json"))
        try Disk.writeJSON(timelineEvents, to: outlineDir.appendingPathComponent("events.json"))
        try Disk.writeJSON(stages, to: outlineDir.appendingPathComponent("stages.json"))
        try Disk.writeJSON(clues, to: ProjectLayout.cluesFile(rootURL))
        try Disk.writeJSON(MemoryFile(facts: facts, aliases: characterAliases, dismissedConflicts: dismissedConflicts), to: ProjectLayout.memoryFile(rootURL))
        try Disk.writeJSON(proposals, to: ProjectLayout.proposalsFile(rootURL))
        dirtyChapters.removeAll()
    }

    private func chapterMetaURL(_ n: Int) -> URL {
        ProjectLayout.chapterDir(rootURL, number: n).appendingPathComponent("meta.json")
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

    static func todayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
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
        applyPayload(p.payload, chapter: p.chapterNumber)
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

    /// 采纳提案 = 把 payload 写入权威状态（宿主裁决的唯一入口）
    func applyPayload(_ payload: ProposalPayload, chapter: Int?) {
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
            guard let n = chapter else { break }
            updateChapter(n) { $0.skeleton = sk; if $0.status == .empty { $0.status = .skeletoned } }
        case .draft(let draft):
            // 作者采纳草稿才走到这里；覆盖前自动快照，正文永远可回滚
            guard let n = chapter else { break }
            if let existing = self.chapter(n), !existing.prose.isEmpty {
                _ = snapshotProse(chapter: n, tag: "采纳草稿前")
            }
            updateChapter(n) {
                $0.prose = draft.text
                if $0.status == .empty || $0.status == .skeletoned || $0.status == .writing { $0.status = .written }
            }
        case .memoryPack(let newFacts, let summary, let newClues):
            for f in newFacts { facts.append(f) }
            for c in newClues where !clues.contains(where: { $0.id == c.id }) {
                var cand = c
                if cand.id.isEmpty { cand.id = nextClueID() }
                clues.append(cand)
            }
            guard let n = chapter else { break }
            updateChapter(n) { $0.summary = summary }
        case .report, .deslop, .memo:
            break // 报告类提案已展示在收件箱，无需入库
        }
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
        let name = "\(stamp)-\(tag).md"
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
        updateChapter(n) { $0.prose = text }
    }

    static func fileStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
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

    // MARK: - Checkpoint（FxAgent 会话状态持久化）

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
