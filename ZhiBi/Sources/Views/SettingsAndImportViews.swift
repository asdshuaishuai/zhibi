import SwiftUI

// MARK: - 导入预览（作者逐项确认后再入库）

struct ImportPreviewSheet: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var confirmOverwrite = false

    /// 本次导入内部重复的章号（后者会覆盖前者）
    private var duplicateChapterCount: Int {
        guard let items = vm.importPreview?.items.filter({ $0.kind == .chapter }) else { return 0 }
        let nums = items.compactMap(\.chapterNumber)
        return nums.count - Set(nums).count
    }

    /// 并入当前作品时，预览里会覆盖已有正文的章数
    private var overwriteCount: Int {
        guard !vm.importTargetNewProject, let store = vm.store, let preview = vm.importPreview else { return 0 }
        return preview.items.filter { item in
            guard item.kind == .chapter, let n = item.chapterNumber,
                  let existing = store.chapter(n) else { return false }
            return !existing.prose.isEmpty
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导入预览").font(.headline)
                if let s = vm.importPreview {
                    Text(s.detectedLayout)
                        .font(.caption).foregroundStyle(.teal)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.teal.opacity(0.1))
                        .cornerRadius(6)
                }
                Spacer()
            }

            if vm.importPostConfirm {
                postConfirmView
            } else {
                Toggle("导入为新书", isOn: $vm.importTargetNewProject)
                    .font(.callout)
                if vm.importTargetNewProject {
                    TextField("新书名", text: $vm.importNewProjectTitle)
                        .textFieldStyle(.roundedBorder)
                } else if let store = vm.store {
                    Text("并入当前作品：\(store.project.title)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("当前没有打开的作品，请选择「导入为新书」。").font(.caption).foregroundStyle(.orange)
                }

                if vm.importScanning {
                    VStack(spacing: ZBSpace.sm) {
                        ProgressView().controlSize(.regular)
                        Text("正在扫描目录与正文（大书可能需要几秒）…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let s = vm.importPreview {
                    Text("识别到 \(s.chapters) 章 · \(s.canon) 份设定 · \(s.outlines) 份大纲")
                        .font(.callout.bold())
                    if duplicateChapterCount > 0 {
                        Label("本次导入有 \(duplicateChapterCount) 个重复章号，后一个文件会覆盖前一个",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if overwriteCount > 0 {
                        Label("其中 \(overwriteCount) 章与当前作品章号重复，确认后会覆盖已有正文（覆盖前会自动存快照）",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Table(of: ImportItem.self, selection: .constant(Set<ImportItem.ID>())) {
                        TableColumn("类型") { item in
                            Picker("", selection: Binding(
                                get: { item.kind },
                                set: { vm.setItemKind(item, $0) })) {
                                ForEach([ImportItem.Kind.chapter, .canon, .outline, .skip], id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .controlSize(.mini)
                        }.width(90)
                        TableColumn("来源") { item in Text(item.sourceName).font(.caption) }
                        TableColumn("标题") { item in Text(item.title).font(.caption) }
                        TableColumn("字数") { item in Text("\(WordStats.chineseCount(item.content))").font(.caption.monospacedDigit()) }.width(70)
                    } rows: {
                        ForEach(vm.importPreview?.items ?? []) { item in
                            TableRow(item)
                        }
                    }
                } else {
                    VStack {
                        ProgressView().controlSize(.small)
                        Text("准备导入预览…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack {
                    Text("导入不会改动你的原目录；结构化伏笔/时间线建议导入后用「AI 盘点伏笔」「AI 建大纲 / 时间线」提案重建。")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("取消") { dismiss() }
                    Button("确认导入") {
                        if overwriteCount > 0 { confirmOverwrite = true } else { performImport() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.importScanning || (!vm.importTargetNewProject && vm.store == nil))
                    .confirmationDialog("有 \(overwriteCount) 章会被覆盖", isPresented: $confirmOverwrite) {
                        Button("覆盖并导入", role: .destructive) { performImport() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("被覆盖的章会先自动存一份快照，可在章节目录 snapshots/ 回滚。")
                    }
                }
            }
        }
        .padding(ZBSpace.lg)
        .frame(width: ZBSpace.Sheet.wide, height: 560)
    }

    private func performImport() {
        if vm.importTargetNewProject {
            vm.confirmImport()
        } else if let store = vm.store {
            vm.confirmImport(intoExisting: store)
        }
    }

    // MARK: 确认导入后：AI 归类在本窗内跑，进度与结果就地反馈（不去收件箱）

    @ViewBuilder
    private var postConfirmView: some View {
        VStack(alignment: .leading, spacing: ZBSpace.sm) {
            Label(vm.importClassifying ? "导入完成 ✓ · AI 正在归类设定…" : "导入完成 ✓ · 设定归类结果",
                  systemImage: vm.importClassifying ? "cpu" : "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(vm.importClassifying ? Color.accentColor : Color.green)

            if vm.importClassifying {
                VStack(alignment: .leading, spacing: ZBSpace.xs) {
                    ProgressView().controlSize(.small)
                    ForEach(ai.lastToolLog.suffix(3), id: \.self) { line in
                        Text(line).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("读全部设定文档，逐篇给出分类与改名建议——完成后在本窗内过目采纳。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let err = ai.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("资料已导入成功，只是归类没跑成——可在「AI 工具箱 → 设定归类」重跑。")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            } else {
                classifyResult
            }

            HStack {
                Spacer()
                // 归类没跑完也可以走：AI 继续在后台跑，结果照常进收件箱（状态条兜底）
                Button(vm.importClassifying ? "转入后台" : "完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// 本次归类提案的就地审阅（与 AI 工具箱的设定归类同款：列表 + 全部采纳）
    @ViewBuilder
    private var classifyResult: some View {
        if let store = vm.store,
           let p = store.proposals.first(where: { ai.lastRunProposalIDs.contains($0.id) && $0.capability == .canonClassify }),
           case .canonClassify(let items) = p.payload {
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                HStack {
                    Label("归类结果（\(items.count) 篇）", systemImage: "square.grid.3x3.square")
                        .font(.caption.bold())
                    Spacer()
                    switch p.status {
                    case .pending:
                        Button("全部采纳") { store.acceptProposal(p.id) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    case .accepted:
                        Label("已采纳 ✓——设定页已按类别分组", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .rejected:
                        Label("已拒收", systemImage: "xmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.title).font(.caption).frame(maxWidth: 200, alignment: .leading)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(item.category)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .cornerRadius(4)
                                if let rename = item.rename, !rename.isEmpty, rename != item.title {
                                    Text("改名：\(rename)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let note = item.note, !note.isEmpty {
                                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                                        .frame(maxWidth: 200, alignment: .trailing).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
                if let issues = store.lastAcceptIssues, p.status == .pending {
                    Text(issues).font(.caption2).foregroundStyle(.orange)
                }
                Text("采纳 = 写回分类与改名（按标题匹配；改名撞名自动跳过，不丢文档）。逐条微调可去「提案收件箱」。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: ZBSpace.xs) {
                Text("本次没有产出归类提案。").font(.caption).foregroundStyle(.secondary)
                Text("可在「AI 工具箱 → 设定归类」重跑。").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension AppViewModel {
    fileprivate func setItemKind(_ item: ImportItem, _ kind: ImportItem.Kind) {
        guard var preview = importPreview,
              let idx = preview.items.firstIndex(where: { $0.id == item.id }) else { return }
        preview.items[idx].kind = kind
        importPreview = preview
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var vm: AppViewModel
    @StateObject private var hub = ModelHubModel()
    /// 保存成功反馈（1.5s 后自动消失）
    @State private var savedFlash = false
    /// 选目录模型后按上下文元信息自动调整包预算的提示
    @State private var budgetNote = ""
    /// 端点连通性测试
    @State private var testing = false
    @State private var testResult: AIService.EndpointTestResult?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            modelTab
                .tabItem { Label("模型服务", systemImage: "cpu") }
            generationTab
                .tabItem { Label("生成与上下文", systemImage: "slider.horizontal.3") }
        }
        .frame(width: ZBSpace.Sheet.standard, height: 560)
        .onAppear {
            hub.onPick = { entry in
                vm.config.baseURL = entry.baseURL
                vm.config.model = entry.modelID
                // 上下文包预算按 models.dev 元信息自动对齐：取模型上下文的一半
                // （留足输出与回复空间），夹在 2K–32K 的既有步进范围内
                if let limit = entry.contextLimit {
                    // 预算 = 上下文 40%：其余留给创作法典/骨架/输出与回复
                    let budget = max(2000, min(32000, limit * 2 / 5))
                    vm.config.contextTokenBudget = budget
                    budgetNote = "已按「\(entry.modelName)」（\(limit / 1000)K 上下文）自动调整包预算 ≈\(budget) tokens"
                } else {
                    budgetNote = ""
                }
            }
            hub.loadInitial()
        }
        .onChange(of: hub.providers) { _ in
            hub.syncSelection(baseURL: vm.config.baseURL, model: vm.config.model)
        }
    }

    /// 模型目录选择（数据源 models.dev，架构对齐 ai-sdk 的 provider 抽象）
    // MARK: - 通用（写作目标 + 外观）

    private var generalTab: some View {
        Form {
            Section("写作目标") {
                Stepper("每日目标：\(vm.dailyGoal) 字", value: $vm.dailyGoal, in: 200...20000, step: 100)
            }
            Section("外观") {
                Picker("主题", selection: $vm.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            HStack { Spacer(); saveButton }
        }
        .formStyle(.grouped)
    }

    // MARK: - 模型服务（端点来源二选一：预设目录 / 自定义端点）

    /// 当前配置是否命中目录里的某个供应商（用于默认选中「预设」）
    private var usingPreset: Bool {
        !hub.providerID.isEmpty
    }

    private var modelTab: some View {
        Form {
            Picker("端点来源", selection: Binding(
                get: { usingPreset ? 0 : 1 },
                set: { source in
                    if source == 0 {
                        // 切回预设：恢复目录选中项（没有则选第一个支持工具调用的供应商）
                        hub.syncSelection(baseURL: vm.config.baseURL, model: vm.config.model)
                        if hub.providerID.isEmpty, let first = hub.providers.first {
                            hub.selectProvider(first.id, config: vm.config)
                        }
                    } else {
                        hub.providerID = ""
                        hub.modelID = ""
                    }
                })) {
                Text("预设（models.dev 目录）").tag(0)
                Text("自定义端点").tag(1)
            }
            .pickerStyle(.segmented)

            if usingPreset {
                catalogSection
            } else {
                Section("自定义端点（OpenAI 兼容，如局域网 Ollama）") {
                    TextField("Base URL", text: $vm.config.baseURL)
                    TextField("模型 ID", text: $vm.config.model)
                    Text("任何 OpenAI 兼容服务都可用；本机 Ollama 走 http://127.0.0.1:11434/v1。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Section("API Key") {
                SecureField("API Key", text: $vm.config.apiKey)
                Text("保存到 macOS 钥匙串，不落明文文件；泄露后到供应商控制台重置即可。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Section("连接测试") {
                HStack {
                    Button {
                        testing = true
                        testResult = nil
                        Task { testResult = await vm.ai.testEndpoint(vm.config) ; testing = false }
                    } label: {
                        HStack(spacing: 6) {
                            if testing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "antenna.radiowaves.left.and.right") }
                            Text(testing ? "测试中…" : "测试连接")
                        }
                    }
                    .controlSize(.small)
                    .disabled(testing || vm.config.baseURL.isEmpty)
                    Spacer()
                }
                if let r = testResult {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.ok ? Color.green : Color.red)
                            Text(r.ok ? "✅ 连通（\(r.latencyMs) ms）" : "❌ \(r.message)")
                                .font(.caption.bold())
                        }
                        if r.ok {
                            Text("服务端模型 \(r.models.count) 个"
                                 + (r.modelFound == true ? "｜当前模型在清单 ✓"
                                    : r.modelFound == false ? "｜⚠ 当前模型 ID 不在清单"
                                    : "")).font(.caption2).foregroundStyle(.secondary)
                            if let working = r.workingURL, working != vm.config.baseURL {
                                Text("实际可用端点：\(working)").font(.caption2).foregroundStyle(.teal)
                                    .textSelection(.enabled)
                                Button("采用此端点") {
                                    vm.config.baseURL = working
                                    hub.syncSelection(baseURL: working, model: vm.config.model)
                                }
                                .controlSize(.mini)
                            }
                        } else if r.authIssue {
                            Text("在上方填入正确的 API Key 后重新测试。").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            HStack { Spacer(); saveButton }
        }
        .formStyle(.grouped)
    }

    // MARK: - 生成与上下文

    private var generationTab: some View {
        Form {
            Section("生成与上下文") {
                Stepper("上下文包预算：≈\(vm.config.contextTokenBudget) tokens", value: $vm.config.contextTokenBudget, in: 2000...32000, step: 1000)
                Text("造包按此预算真实裁剪（保护层优先、低优先级先压）。本地 8K 模型建议 ≤4000——太大时模型会截断反而丢关键上下文。")
                    .font(.caption2).foregroundStyle(.tertiary)
                TextField("向量模型（可选，如 text-embedding-3-small）", text: Binding(
                    get: { vm.config.embeddingModel ?? "" },
                    set: { vm.config.embeddingModel = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                Text("与对话共用同一 Base URL / API Key。留空时资料库使用本地哈希向量；填了模型后优先用远程嵌入做检索重排，失败会自动回退。")
                    .font(.caption2).foregroundStyle(.tertiary)
                Stepper("单次 AI 请求超时：\(vm.config.effectiveTimeout) 秒",
                        value: Binding(
                            get: { vm.config.effectiveTimeout },
                            set: { vm.config.requestTimeoutSeconds = $0 }),
                        in: 30...1800, step: 30)
                Text("超时后宿主会中断本次请求；已产出的提案保留。")
                    .font(.caption2).foregroundStyle(.tertiary)
                Toggle("正文自动保存（关闭后需 ⌘S 手动保存）", isOn: $vm.config.autoSave)
                    .onChange(of: vm.config.autoSave) { enabled in
                        // 立即生效并持久化，不能等用户再点一次「保存设置」
                        vm.store?.autoSaveEnabled = enabled
                        vm.saveConfig()
                    }
            }
            HStack { Spacer(); saveButton }
        }
        .formStyle(.grouped)
    }

    private var saveButton: some View {
        Button {
            vm.saveConfig()
            vm.store?.autoSaveEnabled = vm.config.autoSave
            savedFlash = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { savedFlash = false }
            }
        } label: {
            Label(savedFlash ? "已保存 ✓" : "保存设置",
                  systemImage: savedFlash ? "checkmark.circle.fill" : "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .tint(savedFlash ? .green : .accentColor)
        .disabled(savedFlash)
        .alert("API Key 没保存上", isPresented: Binding(
            get: { AgentConfig.lastKeySaveFailed },
            set: { if !$0 { AgentConfig.lastKeySaveFailed = false } })) {
            Button("好") {}
        } message: {
            Text("钥匙串写入失败（钥匙串可能已锁定）。其余设置已保存，但重启后 API Key 不会生效。")
        }
    }

    private var catalogSection: some View {
        Section("模型目录（models.dev）") {
            if let issue = AgentConfig.lastLoadIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if hub.providers.isEmpty {
                // 目录未就绪：离线兜底条目
                VStack(alignment: .leading, spacing: 6) {
                    Text(hub.state.summary).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(ModelHub.offlineFallbacks) { entry in
                            Button(entry.providerName) {
                                vm.config.baseURL = entry.baseURL
                                vm.config.model = entry.modelID
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("目录拉取失败时可用以上内置条目；联网后点刷新恢复完整目录。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                HStack {
                    Text(hub.state.summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        hub.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("刷新模型目录（models.dev）")
                }
                Picker("供应商", selection: Binding(
                    get: { hub.providerID },
                    set: { hub.selectProvider($0, config: vm.config) })) {
                    ForEach(hub.providers) { p in
                        Text("\(p.name)（\(p.models.filter(\.toolCall).count)）").tag(p.id)
                    }
                }
                if !hub.providerID.isEmpty {
                    Picker("模型", selection: Binding(
                        get: { hub.modelID },
                        set: { hub.selectModel($0) })) {
                        ForEach(hub.modelEntries(toolCallOnly: false)) { m in
                            Text(m.toolCall ? m.name : "⚠︎ \(m.name)（不支持工具）").tag(m.id)
                        }
                    }
                    if let p = hub.providers.first(where: { $0.id == hub.providerID }),
                       let m = p.models.first(where: { $0.id == hub.modelID }) {
                        Text(m.capabilitySummary)
                            .font(.caption2).foregroundStyle(.secondary)
                        if !budgetNote.isEmpty {
                            Text(budgetNote).font(.caption2).foregroundStyle(.teal)
                        }
                        if !m.toolCall {
                            Text("该模型不支持工具调用——执笔的提案工具依赖工具调用，请换同供应商其他模型。")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Text("端点 \(p.baseURL)").font(.caption2).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("选一个供应商即可套用其端点与模型。").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
