import Foundation
import AppKit
import Combine

/// 根应用状态：项目列表、当前打开的项目、AI 服务
@MainActor
final class AppViewModel: ObservableObject {
    enum Screen: Hashable {
        case welcome
        case project
    }

    @Published var screen: Screen = .welcome
    @Published var projects: [ProjectRef] = []
    @Published var store: ProjectStore?
    @Published var config: AgentConfig = AgentConfig.load()
    @Published var importPreview: ImportSummary?
    @Published var showImportPreview = false
    @Published var requestImportViaPanel = false
    @Published var importTargetNewProject = true
    @Published var importNewProjectTitle = ""
    /// 每日写作目标（字）
    @Published var dailyGoal: Int {
        didSet { UserDefaults.standard.set(dailyGoal, forKey: "dailyGoal") }
    }

    /// 外观模式（跟随系统 / 浅色 / 深色）
    @Published var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            AppearanceMode.apply(appearanceMode)
        }
    }

    /// AI 状态条触发的跨视图跳转（如"查看提案"→收件箱）
    @Published var navigateToSection: WorkspaceSection?

    let ai = AIService()

    init() {
        dailyGoal = UserDefaults.standard.object(forKey: "dailyGoal") as? Int ?? 2000
        projects = ProjectRegistry.load()
        appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system
    }

    /// 书架卡牌：换封面风格（直接改 project.json，返回新风格序号）
    func cycleCoverStyle(for ref: ProjectRef) -> Int? {
        let file = ProjectLayout.projectFile(ref.url)
        guard var project = try? Disk.readJSON(NovelProject.self, from: file) else { return nil }
        let base = project.coverStyle ?? CoverStyle.defaultIndex(for: project.title)
        let next = (base + 1) % CoverStyle.count
        project.coverStyle = next
        do { try Disk.writeJSON(project, to: file) } catch { return nil }
        return next
    }

    /// 工具栏一键循环：跟随系统 → 浅色 → 深色
    func cycleAppearance() {
        switch appearanceMode {
        case .system: appearanceMode = .light
        case .light: appearanceMode = .dark
        case .dark: appearanceMode = .system
        }
    }

    // MARK: - 项目管理

    func createProject(title: String, genre: String, premise: String, wordTarget: Int) {
        let base = ProjectLayout.safeFileName(title)
        var dir = defaultProjectsDir().appendingPathComponent("\(base).zhibi", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = defaultProjectsDir().appendingPathComponent("\(base)-\(suffix).zhibi", isDirectory: true)
            suffix += 1
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: dir)
        store.project = NovelProject(title: title, genre: genre, premise: premise, chapterWordTarget: wordTarget)
        try? store.saveNow()
        open(store: store)
    }

    func openProject(_ ref: ProjectRef) {
        let store = ProjectStore(rootURL: ref.url)
        do {
            try store.load()
            open(store: store)
        } catch {
            // 空目录或损坏：尝试直接打开
            open(store: store)
        }
    }

    private func open(store: ProjectStore) {
        self.store = store
        screen = .project
        if let idx = projects.firstIndex(where: { $0.url == store.rootURL }) {
            projects[idx].lastOpenedAt = Date()
        } else {
            projects.append(ProjectRef(title: store.project.title, url: store.rootURL))
        }
        ProjectRegistry.save(projects)
    }

    func closeProject() {
        try? store?.saveNow()
        store = nil
        screen = .welcome
        projects = ProjectRegistry.load()
    }

    func deleteProject(_ ref: ProjectRef) {
        ProjectStore.moveToTrash(ref.url)
        projects.removeAll { $0.id == ref.id }
        ProjectRegistry.save(projects)
    }

    private func defaultProjectsDir() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("执笔", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 导入

    func beginImport(urls: [URL]) {
        guard let url = urls.first else { return }
        let isDir = url.isDirectoryURL
        importPreview = isDir ? ImportService.scan(url) : ImportService.scanSingleFile(url)
        let guess = ImportService.titleGuess(from: importPreview ?? ImportSummary(detectedLayout: ""))
        importNewProjectTitle = guess == "导入作品" ? url.deletingPathExtension().lastPathComponent : guess
        importTargetNewProject = true
        showImportPreview = true
    }

    func confirmImport(intoExisting existing: ProjectStore? = nil) {
        guard let preview = importPreview else { return }
        if let existing {
            ImportService.apply(preview, into: existing)
        } else {
            let title = importNewProjectTitle.isEmpty ? "导入作品" : importNewProjectTitle
            let base = ProjectLayout.safeFileName(title)
            var dir = defaultProjectsDir().appendingPathComponent("\(base).zhibi", isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: dir.path) {
                dir = defaultProjectsDir().appendingPathComponent("\(base)-\(suffix).zhibi", isDirectory: true)
                suffix += 1
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = ProjectStore(rootURL: dir)
            store.project.title = title
            ImportService.apply(preview, into: store)
            open(store: store)
        }
        importPreview = nil
    }

    // MARK: - 去AI味建议采纳（首条采纳前自动快照，可回滚）

    @discardableResult
    func applyDeslopSuggestion(_ suggestion: DeslopSuggestion, chapter n: Int, snapshotTag: String? = nil) -> Bool {
        guard let store, var ch = store.chapter(n) else { return false }
        if let tag = snapshotTag {
            _ = store.snapshotProse(chapter: n, tag: tag)
        }
        guard let range = ch.prose.range(of: suggestion.original, options: [.literal]) else { return false }
        ch.prose.replaceSubrange(range, with: suggestion.replacement)
        store.updateChapter(n) {
            $0.prose = ch.prose
        }
        return true
    }

    // MARK: - 导出

    @discardableResult
    func exportManuscript() -> String? {
        guard let store else { return nil }
        do {
            let r = try ExportService.exportManuscript(store: store)
            return "合并稿已导出：\(r.url.path)"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func exportVolumeTxt() -> String? {
        guard let store else { return nil }
        do {
            let r = try ExportService.exportVolumeTxt(store: store)
            return "分卷 TXT 已导出（\(r.filesWritten) 卷）：\(r.url.path)"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func exportOhStory() -> String? {
        guard let store else { return nil }
        do {
            let r = try ExportService.exportOhStory(store: store)
            return "oh-story 目录已导出（\(r.filesWritten) 个文件）：\(r.url.path)"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    func saveConfig() {
        config.persist()
    }
}

extension URL {
    var isDirectoryURL: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? hasDirectoryPath
    }
}
