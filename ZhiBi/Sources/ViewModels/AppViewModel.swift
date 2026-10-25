import Foundation
import AppKit
import Combine

/// 从资料库/来源芯片跳到正文时要定位的原文片段。token 每次点击都换，
/// 同一个词连点两次也能再次闪烁定位。
struct ChapterFocus: Equatable {
    var chapter: Int
    var needle: String?
    var token: UUID = UUID()
}

/// 跨视图把一段提示词送进右侧对话输入框（资料库「交给 AI」等）。
struct ChatInvocation: Equatable {
    var prompt: String
    var chapter: Int?
    var token: UUID = UUID()
}

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
    @Published var projectOpenError: String?
    @Published var openingProject = false
    /// 全局轻提示（操作反馈）：自动 2.6s 消失，点一下可提前关
    @Published var toast: String?
    @Published var toastSuccess = true
    private var toastTask: Task<Void, Never>?

    func showToast(_ text: String, success: Bool = true) {
        toast = text
        toastSuccess = success
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
    @Published var navigateToSection: WorkspaceSection?
    /// 资料库命中的原文定位指令（章节编辑器消费）
    @Published var chapterFocus: ChapterFocus?
    /// 资料库「交给 AI」：把提示词送进右侧对话（面板消费者会清空）
    @Published var chatInvocation: ChatInvocation?

    let ai = AIService()

    init() {
        dailyGoal = UserDefaults.standard.object(forKey: "dailyGoal") as? Int ?? 2000
        projects = ProjectRegistry.load()
        appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system
        ai.loadPersistedTrajectory()
    }

    /// 书架卡牌：换封面风格（盘 IO 在后台线程，返回新风格序号）
    func cycleCoverStyle(for ref: ProjectRef) async -> Int? {
        // 工程正开着：必须改内存里的 store，否则后台整份写 project.json
        // 会和 store 的下一次保存互相覆盖。
        if let store, store.rootURL == ref.url {
            let base = store.project.coverStyle ?? CoverStyle.defaultIndex(for: store.project.title)
            let next = (base + 1) % CoverStyle.count
            store.project.coverStyle = next
            store.saveSoon()
            return next
        }
        let file = ProjectLayout.projectFile(ref.url)
        return await Task.detached(priority: .utility) {
            guard var project = try? Disk.readJSON(NovelProject.self, from: file) else { return nil }
            let base = project.coverStyle ?? CoverStyle.defaultIndex(for: project.title)
            let next = (base + 1) % CoverStyle.count
            project.coverStyle = next
            do { try Disk.writeJSON(project, to: file) } catch { return nil }
            return next
        }.value
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

    func createProject(title: String, genre: String, premise: String, wordTarget: Int, buildFramework: Bool = false) {
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
        // 新书必须有第一章：否则打开后右侧只有「选择或新建一个章节」，
        // 而新手引导条挂在编辑器内部，零章时永远看不见。
        _ = store.ensureChapter(1)
        do {
            try store.saveNow()
        } catch {
            projectOpenError = "新书创建失败：\(error.localizedDescription)（检查磁盘/权限后重试）"
            return
        }
        open(store: store)
        if buildFramework {
            // 创建即搭框架：全部走提案通道（收件箱待审），核心机制不变
            let g = genre.isEmpty ? "题材待定" : genre
            let p = premise.isEmpty ? "（作者暂未填写核心，先给保守版本）" : premise
            Task { await ai.runBootstrapFramework(store: store, config: config,
                                                  premise: "《\(title)》｜题材：\(g)｜一句话核心：\(p)") }
        }
    }

    /// 打开项目：读盘在后台（大书/iCloud 卷上不再卡死界面），完成后回主线程切换。
    func openProject(_ ref: ProjectRef) {
        guard !openingProject else { return }
        openingProject = true
        let store = ProjectStore(rootURL: ref.url)
        Task {
            defer { openingProject = false }
            do {
                try await store.loadAsync()
                open(store: store)
            } catch {
                // 空目录（project.json 不存在）= 正常新书路径；文件在但解析失败 = 损坏，
                // 不能静默开空 store——否则退出时保存会用默认值覆盖整个账本
                let projectFile = ProjectLayout.projectFile(ref.url)
                if FileManager.default.fileExists(atPath: projectFile.path) {
                    projectOpenError = "项目文件损坏，已中止打开（原文件未被改动）。\(projectFile.path) 可手动检查该 JSON，或从备份恢复。"
                } else {
                    open(store: store)
                }
            }
        }
    }

    private func open(store: ProjectStore) {
        self.store = store
        // 对话是项目级状态：切换作品时清掉上一本的流式片段/错误/提案提示，
        // 否则新书右侧会挂着旧书的回答尾巴。
        ai.resetChatSessionState()
        // 自动保存开关随持久化配置恢复，而不是等用户进章编辑器
        store.autoSaveEnabled = config.autoSave
        screen = .project
        if let idx = projects.firstIndex(where: { $0.url == store.rootURL }) {
            projects[idx].lastOpenedAt = Date()
        } else {
            projects.append(ProjectRef(title: store.project.title, url: store.rootURL))
        }
        ProjectRegistry.save(projects)
    }

    func closeProject() {
        ProseEditorFlush.now()
        if let store {
            do {
                try store.saveNow()
            } catch {
                // 错误不能挂在即将释放的 store 上：那等于静默失败
                let alert = NSAlert()
                alert.messageText = "保存失败，尚未返回书架"
                alert.informativeText = error.localizedDescription
                    + "\n\n留在项目里可以重试保存（自动保存会继续尝试）；仍要返回则未落盘的修改可能丢失。"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "留在这里重试")
                alert.addButton(withTitle: "仍要返回")
                if alert.runModal() == .alertFirstButtonReturn { return }
            }
        }
        store = nil
        screen = .welcome
        projects = ProjectRegistry.load()
    }

    func deleteProject(_ ref: ProjectRef) {
        if FileManager.default.fileExists(atPath: ref.url.path), !ProjectStore.moveToTrash(ref.url) {
            showToast("无法移到废纸篓（检查权限/磁盘），项目未删除。", success: false)
            return
        }
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

    @Published var importScanning = false
    /// 确认导入后：导入窗不关，留在本窗内跑「AI 归类设定」并就地反馈结果（不逼用户去收件箱找）
    @Published var importPostConfirm = false
    @Published var importClassifying = false

    /// 大目录扫描放后台（主线程同步读会卡界面），预览窗先开并显示扫描状态
    func beginImport(urls: [URL]) {
        guard let url = urls.first else { return }
        let isDir = url.isDirectoryURL
        importScanning = true
        importPreview = nil
        importPostConfirm = false
        importClassifying = false
        showImportPreview = true
        Task {
            let summary = isDir
                ? await Task.detached(priority: .userInitiated) { ImportService.scan(url) }.value
                : ImportService.scanSingleFile(url)
            importPreview = summary
            let guess = ImportService.titleGuess(from: summary)
            importNewProjectTitle = guess == "导入作品" ? url.deletingPathExtension().lastPathComponent : guess
            importTargetNewProject = true
            importScanning = false
        }
    }

    func confirmImport(intoExisting existing: ProjectStore? = nil) {
        guard let preview = importPreview else { return }
        var importedInto: ProjectStore?
        do {
            if let existing {
                try ImportService.apply(preview, into: existing)
                importedInto = existing
            } else {
                let title = importNewProjectTitle.isEmpty ? "导入作品" : importNewProjectTitle
                let base = ProjectLayout.safeFileName(title)
                var dir = defaultProjectsDir().appendingPathComponent("\(base).zhibi", isDirectory: true)
                var suffix = 2
                while FileManager.default.fileExists(atPath: dir.path) {
                    dir = defaultProjectsDir().appendingPathComponent("\(base)-\(suffix).zhibi", isDirectory: true)
                    suffix += 1
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let store = ProjectStore(rootURL: dir)
                store.project.title = title
                try ImportService.apply(preview, into: store)
                open(store: store)
                importedInto = store
            }
        } catch {
            // 预览窗保持打开，作者可检查磁盘/权限后重试；绝不显示"导入完成"
            showToast("导入失败：\(error.localizedDescription)", success: false)
            return
        }
        importPreview = nil
        showToast("导入完成：\(preview.chapters) 章 · 设定/大纲 \(preview.canon + preview.outlines) 篇")
        // 有可用端点时，导入完成就在本窗内跑设定归类：进度与结果就地反馈（铁律不变：归类提案仍
        // 登记收件箱留痕，窗内「全部采纳」走同一条 acceptProposal）。没得跑就直接收窗。
        if let store = importedInto, !config.baseURL.isEmpty, !store.canonSections.isEmpty {
            importPostConfirm = true
            importClassifying = true
            Task {
                await ai.runCanonClassify(store: store, config: config)
                importClassifying = false
            }
        } else {
            importPostConfirm = false
            showImportPreview = false
        }
    }

    // MARK: - 去AI味建议采纳（首条采纳前自动快照，可回滚）

    /// 最近一次去AI味采纳失败的具体原因（原文找不到 / 出现多次），供收件箱就地提示
    @Published var lastDeslopIssue: String?

    @discardableResult
    func applyDeslopSuggestion(_ suggestion: DeslopSuggestion, chapter n: Int,
                               snapshotTag: String? = nil, targetDraftID: UUID? = nil) -> Bool {
        lastDeslopIssue = nil
        guard let store else { return false }
        guard !suggestion.original.isEmpty else {
            lastDeslopIssue = "建议的原文为空，无法定位。"
            return false
        }
        // 送审的是草稿：建议必须改回草稿提案，绝不能动已入库正文。
        // 草稿已采纳后，同样的文本已进正文，才允许落到正文；
        // 草稿被拒绝/已不存在时不能悄悄改正文。
        if let draftID = targetDraftID {
            guard let idx = store.proposals.firstIndex(where: { $0.id == draftID }) else {
                lastDeslopIssue = "目标草稿已不存在，建议不再应用。"
                return false
            }
            switch store.proposals[idx].status {
            case .rejected:
                lastDeslopIssue = "目标草稿已被拒绝，建议不再应用。"
                return false
            case .pending:
                guard case .draft(var draft) = store.proposals[idx].payload else {
                    lastDeslopIssue = "目标提案不是草稿，无法应用。"
                    return false
                }
                guard let range = uniqueRange(of: suggestion.original, in: draft.text) else { return false }
                draft.text.replaceSubrange(range, with: suggestion.replacement)
                store.proposals[idx].payload = .draft(draft)
                store.saveSoon()
                return true
            case .accepted:
                break   // 草稿已进正文：继续走下面的正文替换
            }
        }
        guard var ch = store.chapter(n) else { return false }
        guard let range = uniqueRange(of: suggestion.original, in: ch.prose) else { return false }
        if let tag = snapshotTag {
            guard store.snapshotProse(chapter: n, tag: tag) != nil else { return false }
        }
        ch.prose.replaceSubrange(range, with: suggestion.replacement)
        store.updateChapter(n) {
            $0.prose = ch.prose
        }
        return true
    }

    /// 只允许替换唯一命中的片段：同一句出现多次时静默改第一处，很可能改错位置。
    private func uniqueRange(of needle: String, in text: String) -> Range<String.Index>? {
        var count = 0
        var first: Range<String.Index>?
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: needle, options: [.literal], range: searchStart..<text.endIndex) {
            count += 1
            if first == nil { first = r }
            if count > 1 { break }
            searchStart = r.upperBound
        }
        if count == 0 {
            lastDeslopIssue = "原文在目标文本里找不到（可能已被你手改）。"
            return nil
        }
        if count > 1 {
            lastDeslopIssue = "原文出现 \(count) 次，无法确定改哪一处——请手动修改。"
            return nil
        }
        return first
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
