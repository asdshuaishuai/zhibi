import SwiftUI

/// 章节编辑器：上=骨架（AI 提案→人改→人批），下=正文（手写或采纳 AI 草稿后由作者定稿）。
/// 工具栏动作全部产出提案或报告；整章草稿走 propose_draft，作者采纳前不进正文。
struct ChapterEditorView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int

    @State private var directive = ""
    @State private var showSkeletonEditor = true
    @State private var lintResult: LintSummary?
    @State private var newNote = ""
    @State private var showSnapshots = false
    @State private var showRecall = false
    @State private var showPipeline = false
    @State private var showInbox = false
    @State private var showToolbox = false
    @State private var dossierHintShown: Set<Int> = []
    @State private var bannerDismissed = false

    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("dailyGoal") private var dailyGoal = 2000

    @AppStorage("proseCentered") private var proseCentered = true
    @AppStorage("proseSerif") private var proseSerif = false
    @AppStorage("proseFontSize") private var proseFontSize = 15.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chapter: Chapter { store.chapter(chapterNumber) ?? Chapter(number: chapterNumber) }

    /// 只有选中了本章的资料库命中，才把定位指令交给正文编辑器。
    private var proseFocus: ChapterFocus? {
        guard let focus = vm.chapterFocus, focus.chapter == chapterNumber else { return nil }
        return focus
    }

    /// 每日目标环：今日净增 / 目标
    private var dailyChip: some View {
        let today = store.todayWordCount()
        let frac = dailyGoal > 0 ? min(1.0, Double(max(0, today)) / Double(dailyGoal)) : 0
        let done = frac >= 1.0
        return HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: frac)
                    .stroke(done ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 17, height: 17)
            Text(done ? "今日达成" : "今日 +\(today)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(done ? Color.green : Color.secondary)
        }
        .help("今日净增 \(today) 字 / 目标 \(dailyGoal) 字（设置里可改）")
    }

    private var proseNSFont: NSFont {
        if proseSerif, let f = NSFont(name: "STSongti-SC-Regular", size: proseFontSize) { return f }
        return NSFont.systemFont(ofSize: proseFontSize)
    }

    /// 活跃伏笔关键词（高亮针）：标题 + 种下原文前4字
    private var clueNeedles: [String] {
        var needles: [String] = []
        for c in store.activeClues(currentChapter: chapterNumber) {
            let title = c.title.trimmingCharacters(in: .whitespaces)
            if title.count >= 2 { needles.append(title) }
            let quote = c.plantedQuote.trimmingCharacters(in: .whitespaces)
            if quote.count >= 4 { needles.append(String(quote.prefix(6))) }
        }
        var seen = Set<String>()
        return needles.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSkeletonEditor && !focusMode {
                SkeletonPanel(vm: vm, store: store, chapterNumber: chapterNumber,
                              collapsed: $showSkeletonEditor)
                .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity))
                Divider()
            }
            proseEditor
        }
        .animation(ZBMotion.standard(reduceMotion: reduceMotion), value: showSkeletonEditor)
        .onChange(of: directive) { newValue in
            let current = store.chapter(chapterNumber)?.directive ?? ""
            if current != newValue {
                store.updateChapter(chapterNumber) { $0.directive = newValue }
            }
        }
        .onAppear {
            store.autoSaveEnabled = vm.config.autoSave
            // 本章指令持久化在章 meta 里，切章不会丢
            directive = store.chapter(chapterNumber)?.directive ?? ""
            // 首次进入时若本章刚写完但还没档案卡，轻提示（每章一次）
            if let ch = store.chapter(chapterNumber), !ch.prose.isEmpty,
               !store.dossiers.contains(where: { $0.chapter == chapterNumber }),
               !dossierHintShown.contains(chapterNumber) {
                dossierHintShown.insert(chapterNumber)
                vm.showToast("本章还没档案卡——「AI 协作 → 提取档案卡」可入长程记忆库", success: false)
            }
        }
        .sheet(isPresented: $showSnapshots) {
            SnapshotBrowser(vm: vm, store: store, chapterNumber: chapterNumber)
        }
        .sheet(isPresented: $showPipeline) {
            PipelineSheet(vm: vm, store: store, chapterNumber: chapterNumber)
            // 不拦关窗：任务在后台继续、结果进收件箱；拦着反而像卡死
        }
        .sheet(isPresented: $showInbox) {
            ProposalInboxView(vm: vm, store: store, onClose: { showInbox = false })
                .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 480)
        }
        .sheet(isPresented: $showRecall) {
            RecallSheetView(vm: vm, store: store, chapterNumber: chapterNumber, directive: directive)
                .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 520)
        }
        .sheet(isPresented: $showToolbox) {
            AIToolboxSheet(vm: vm, store: store, ai: vm.ai, chapterNumber: chapterNumber)
                .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 560)
        }
    }

    // MARK: 头部（左：章节信息；右：三个主动作 + AI 协作菜单）

    private var header: some View {
        HStack(spacing: 8) {
            TextField("章节标题", text: Binding(
                get: { chapter.title },
                set: { newValue in store.updateChapter(chapterNumber) { $0.title = newValue } }))
                .textFieldStyle(.plain)
                .font(.title3.bold())
                .frame(maxWidth: 240)

            Picker("", selection: Binding(
                get: { chapter.status },
                set: { newValue in store.updateChapter(chapterNumber) { $0.status = newValue } })) {
                ForEach(ChapterStatus.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .frame(width: 96)
            .labelsHidden()

            Button {
                withAnimation { showSkeletonEditor.toggle() }
            } label: {
                Image(systemName: showSkeletonEditor ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
            }
            .help(showSkeletonEditor ? "收起骨架面板" : "展开骨架面板")
            .accessibilityLabel(showSkeletonEditor ? "收起骨架面板" : "展开骨架面板")

            if let lint = lintResult {
                aiTasteBadge(lint)
            }

            typesetMenu

            Button {
                showPipeline = true
            } label: {
                Label("一键成章", systemImage: "flowchart")
            }
            // ⌘⇧W 是「关闭窗口」的习惯位，长任务入口改用 ⌘↩
            .keyboardShortcut(.return, modifiers: .command)
            .help("流水线：主线→骨架→写作→审查→修复→记忆/文风审查（⌘↩）")

            dailyChip

            Button {
                focusMode.toggle()
            } label: {
                Image(systemName: focusMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help(focusMode ? "退出专注模式（⌘⇧F）" : "专注模式：只留稿纸（⌘⇧F）")
            .accessibilityLabel(focusMode ? "退出专注模式" : "进入专注模式")

            Spacer(minLength: 8)

            // AI 协作菜单：召回 / 记录 / 快照
            Menu {
                // 低频动作用菜单收口：编辑器头部在 1020pt 窗口下放不下太多独立按钮
                Button {
                    Task { await vm.ai.runSkeleton(store: store, config: vm.config, chapter: chapterNumber, directive: directive) }
                } label: {
                    Label("搭骨架（提案）", systemImage: "bone")
                }
                .disabled(vm.ai.running)
                Button {
                    Task { await vm.ai.runValidation(store: store, config: vm.config, chapter: chapterNumber) }
                } label: {
                    Label("一键验证", systemImage: "checkmark.seal")
                }
                .disabled(vm.ai.running)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button {
                    Task { await vm.ai.runDeslop(store: store, config: vm.config, chapter: chapterNumber) }
                } label: {
                    Label("去AI味", systemImage: "sparkles")
                }
                .disabled(vm.ai.running)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button {
                    showRecall = true
                } label: {
                    Label("一键召回（上下文包）", systemImage: "arrow.triangle.pull")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button {
                    Task { await vm.ai.runMemoryExtract(store: store, config: vm.config, chapter: chapterNumber) }
                } label: {
                    Label("让 AI 记一笔（记忆/伏笔候选）", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(vm.ai.running)
                Button {
                    Task { await vm.ai.runDossierExtract(store: store, config: vm.config, chapter: chapterNumber) }
                } label: {
                    Label("提取档案卡（长程记忆）", systemImage: "books.vertical")
                }
                .help("本章的场景/人物/推进/悬念/关键细节 → 跨全书可检索的档案卡")
                .disabled(vm.ai.running)
                Button {
                    Task { await vm.ai.runClueInventory(store: store, config: vm.config, scope: "") }
                } label: {
                    Label("AI 盘点伏笔（全书）", systemImage: "link")
                }
                .disabled(vm.ai.running)
                Divider()
                Button {
                    if store.snapshotProse(chapter: chapterNumber, tag: "手动") != nil {
                        vm.showToast("已保存本章快照")
                    } else {
                        vm.showToast("快照未保存：正文为空或磁盘写入失败", success: false)
                    }
                } label: {
                    Label("保存快照", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    if let latest = store.snapshots(chapter: chapterNumber).first {
                        if store.restoreSnapshot(chapter: chapterNumber, name: latest.name) {
                            vm.showToast("已回滚到「\(latest.name)」")
                        } else {
                            vm.showToast(store.lastSaveError ?? "回滚失败", success: false)
                        }
                    } else {
                        vm.showToast("还没有可回滚的快照", success: false)
                    }
                } label: {
                    Label("回滚到最近快照", systemImage: "arrow.counterclockwise")
                }
                Button {
                    showSnapshots = true
                } label: {
                    Label("浏览快照…", systemImage: "photo.on.rectangle.angled")
                }
            } label: {
                Label("AI 协作", systemImage: "wand.and.stars")
            }
            .fixedSize()

            Button {
                showToolbox = true
            } label: {
                Label("AI 工具箱", systemImage: "wrench.and.screwdriver")
            }
            .disabled(vm.ai.running)
            .help("拆书 / 整理旧稿 / 封面提案 / 短篇成稿")

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var typesetMenu: some View {
        Menu {
            Toggle("居中稿纸版式", isOn: $proseCentered)
            Toggle("宋体正文", isOn: $proseSerif)
            Stepper("字号 \(Int(proseFontSize))", value: $proseFontSize, in: 12...24, step: 1)
        } label: {
            Image(systemName: "textformat.size")
        }
        .help("正文排版")
        .accessibilityLabel("正文排版")
    }

    private func addNote() {
        let note = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        store.updateChapter(chapterNumber) {
            $0.notes = ($0.notes ?? []) + [note]
        }
        newNote = ""
    }

    private func aiTasteBadge(_ lint: LintSummary) -> some View {
        let color: Color = lint.grade == "重度" ? .red : (lint.grade == "中度" ? .orange : .green)
        return Text("AI味 \(lint.grade)")
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(10)
            .help(lint.topIssues.map { "【\($0.kind)】\($0.detail)" }.joined(separator: "\n") + "\n（本地零成本扫描，随打字更新）")
    }

    // MARK: 新书引导条（还没开写时：要么去审框架提案，要么让 AI 搭一个）

    private var onboardingBanner: some View {
        let hasAnyProse = store.chapters.contains { !$0.prose.isEmpty }
        let pending = store.proposals.filter { $0.status == .pending }.count
        return Group {
            if !hasAnyProse && !bannerDismissed {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(ZB.vermillion)
                    if pending > 0 {
                        Text("AI 已搭好框架：\(pending) 条提案待你审（主线/背景设定/时间线）。")
                            .font(.caption)
                        Button("查看提案") { showInbox = true }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                    } else if vm.config.apiKey.isEmpty {
                        Text("这本还是空的。先去「设置」配 API Key，回来一句话搭框架；或者直接开写第一章。")
                            .font(.caption)
                    } else if store.canonSections.isEmpty && store.clues.isEmpty {
                        // 有正文没账本：导入的旧书，先整理再续写（story-import 的整理步骤）
                        Text("这本有正文但账本是空的——先让 AI 整理旧稿（设定与人物 / 剧情时间线 / 伏笔追踪），核对后再续写。")
                            .font(.caption)
                        Button("整理旧稿") { showToolbox = true }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                            .disabled(vm.ai.running)
                    } else {
                        Text("这本还是空的。")
                            .font(.caption)
                        Button("用 AI 搭框架") {
                            let g = store.project.genre.isEmpty ? "题材待定" : store.project.genre
                            let p = store.project.premise.isEmpty ? "（作者暂未填写核心，先给保守版本）" : store.project.premise
                            Task { await vm.ai.runBootstrapFramework(
                                store: store, config: vm.config,
                                premise: "《\(store.project.title)》｜题材：\(g)｜一句话核心：\(p)") }
                        }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                        .disabled(vm.ai.running)
                    }
                    Spacer()
                    Button {
                        bannerDismissed = true
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                .padding(.horizontal, ZBSpace.md).padding(.vertical, ZBSpace.sm)
                .background(ZB.vermillion.opacity(0.06))
            }
        }
    }

    // MARK: 正文编辑器（人的领地）

    private var proseEditor: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("正文（作者定稿）").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("\(chapter.wordCount) 字 / 目标 \(store.project.chapterWordTarget)")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if vm.config.autoSave {
                        Text("自动保存").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                HStack(spacing: 0) {
                    if proseCentered || focusMode { Spacer(minLength: 0) }
                    RichProseEditor(
                        markdown: Binding(
                            get: { chapter.prose },
                            set: { newValue in
                                store.updateChapter(chapterNumber) {
                                    $0.prose = newValue
                                    if $0.status == .skeletoned || $0.status == .empty { $0.status = .writing }
                                }
                            }),
                            baseFont: proseNSFont,
                            textColor: NSColor.labelColor,
                            clueNeedles: clueNeedles,
                            focusNeedle: proseFocus?.needle,
                            focusToken: proseFocus?.token,
                            onLint: { summary in lintResult = summary })
                    .padding(.horizontal, proseCentered || focusMode ? 24 : 8)
                    .frame(maxWidth: proseCentered || focusMode ? 780 : .infinity)
                    if proseCentered || focusMode { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity)
                .background(ZB.paper.opacity(0.6))
            }
            .padding(.bottom, 8)
            onboardingBanner

            // 右栏：作者速记 + AI 运行预览（专注模式下隐藏）
            VStack(alignment: .leading, spacing: 8) {
                // 提案收件箱常驻入口：写作时一键处理提案，不用离开正文去侧栏
                Button {
                    showInbox = true
                } label: {
                    HStack {
                        Image(systemName: "tray.full")
                        Text("提案收件箱")
                        let pending = store.proposals.filter { $0.status == .pending }.count
                        if pending > 0 {
                            Text("\(pending)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.9))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .font(.caption.bold())
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(6)
                }
                .buttonStyle(.borderless)
                .help("AI 的所有产出都在这里等你审过才算数")

                Text("给 AI 的本章指令（可选）").font(.caption.bold()).foregroundStyle(.secondary)
                TextEditor(text: $directive)
                    .font(.callout)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                Text("点击工具栏任意 AI 按钮时，这段话作为你的直接要求随包带上（最高优先级）。")
                    .font(.caption2).foregroundStyle(.tertiary)

                Divider()

                // 随手记：旁路记录——写的时候顺手丢进来，之后"让 AI 记一笔"会一并交给它归档
                Text("随手记（关键节点 / 记忆 / 埋点候选）").font(.caption.bold()).foregroundStyle(.secondary)
                HStack {
                    TextField("记一笔…", text: $newNote)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { addNote() }
                    Button("记") { addNote() }
                        .controlSize(.small)
                        .disabled(newNote.isEmpty)
                }
                ForEach(chapter.noteList, id: \.self) { note in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•").font(.caption2)
                        Text(note).font(.caption2)
                        Spacer()
                        Button {
                            store.updateChapter(chapterNumber) {
                                $0.notes = ($0.notes ?? []).filter { $0 != note }
                            }
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).controlSize(.mini)
                    }
                }

                Divider()

                Text("本章伏笔触点（写完记得对账）").font(.caption.bold()).foregroundStyle(.secondary)
                if let sk = chapter.skeleton, !sk.clueTouches.isEmpty {
                    ForEach(sk.clueTouches) { t in
                        HStack(spacing: 6) {
                            Text("[\(t.clueID)]").font(.caption2.monospaced()).foregroundStyle(.orange)
                            Text("\(t.action.rawValue)：\(t.requirement)").font(.caption2)
                        }
                    }
                } else {
                    Text("（骨架未定或无伏笔触点）").font(.caption2).foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(ZBSpace.sm)
            .opacity(focusMode ? 0 : 1)
                    .frame(minWidth: 250, maxWidth: 330)
                    .frame(width: focusMode ? 0 : nil)
                    .allowsHitTesting(!focusMode)
        }
    }
}

// MARK: - 一键召回弹层：确定性上下文包直显（无需联网），AI 备忘按需生成

struct RecallSheetView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int
    let directive: String
    @Environment(\.dismiss) private var dismiss

    @State private var pack: ContextPack?

    private func buildPack() -> ContextPack {
        ContextPackBuilder.build(store: store, forChapter: chapterNumber, budget: vm.config.contextTokenBudget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.pull")
                Text("第\(chapterNumber)章 写作召回包").font(.headline)
                if let p = pack {
                    Text("≈\(p.approxTokens) tokens · 确定性组装 · 上章结尾/近章摘要/贯穿线/活跃伏笔/角色状态")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("生成写作备忘（提案）") {
                    Task {
                        await vm.ai.runRecall(store: store, config: vm.config, chapter: chapterNumber, directive: directive)
                    }
                }
                .controlSize(.small)
                .disabled(vm.ai.running)
                Button("完成") { dismiss() }
                    .controlSize(.small)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pack?.blocks ?? []) { block in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(block.title).font(.caption.bold())
                                if block.protected {
                                    Text("受保护").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.teal.opacity(0.12)).foregroundStyle(.teal)
                                        .cornerRadius(4)
                                }
                                Spacer()
                                Text("≈\(WordStats.approxTokens(block.content)) tok").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(block.content).font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .zbGlass(cornerRadius: 8)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 720, height: 560)
        .onAppear { if pack == nil { pack = buildPack() } }
    }
}

// MARK: - 快照浏览器

struct SnapshotBrowser: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int
    @Environment(\.dismiss) private var dismiss
    @State private var preview: (name: String, text: String)?
    @State private var snapshots: [(name: String, text: String)] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("快照 · 第\(chapterNumber)章").font(.headline)
                Text("回滚前会把当前稿自动存一份").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("完成") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
            List {
                ForEach(snapshots, id: \.name) { snap in
                    HStack {
                        Text(snap.name).font(.caption.monospaced())
                        Spacer()
                        Button("预览") { preview = snap }.controlSize(.small)
                        Button("回滚到此版本") {
                            if store.restoreSnapshot(chapter: chapterNumber, name: snap.name) {
                                vm.showToast("已回滚到「\(snap.name)」（回滚前版本已自动存快照）")
                                dismiss()
                            } else {
                                vm.showToast(store.lastSaveError ?? "回滚失败", success: false)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                if snapshots.isEmpty {
                    Text("还没有快照。去AI味首次采纳前会自动创建；也可在工具栏手动保存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 300)
            if let preview {
                let diff = WordStats.chineseCount(preview.text) - (store.chapter(chapterNumber)?.wordCount ?? 0)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("快照 vs 当前正文：")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text(diff == 0 ? "字数一致" : (diff > 0 ? "快照多 \(diff) 字" : "快照少 \(-diff) 字"))
                            .font(.caption2.bold())
                            .foregroundStyle(diff == 0 ? Color.secondary : (diff > 0 ? Color.orange : Color.teal))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    MarkdownPreview(markdown: preview.text)
                }
            } else {
                Text("选择一个快照预览").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        .frame(width: 860, height: 520)
        .onAppear { snapshots = store.snapshots(chapter: chapterNumber) }
    }
}

// MARK: - 骨架面板（AI 搭、人填、人批）

struct SkeletonPanel: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int
    @Binding var collapsed: Bool

    private var skeleton: ChapterSkeleton? { store.chapter(chapterNumber)?.skeleton }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                Text("本章骨架").font(.headline)
                if let sk = skeleton {
                    if sk.humanApproved {
                        Text("作者已批准").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15)).foregroundStyle(.green)
                            .cornerRadius(6)
                    } else if sk.proposedByAI {
                        Text("AI 提案 · 待你修改批准").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.12)).foregroundStyle(.indigo)
                            .cornerRadius(6)
                    }
                    Spacer()
                    Button(sk.humanApproved ? "撤回批准" : "批准此骨架") {
                        store.updateChapter(chapterNumber) { ch in
                            guard var skt = ch.skeleton else { return }
                            skt.humanApproved.toggle()
                            skt.approvedAt = skt.humanApproved ? Date() : nil
                            ch.skeleton = skt
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(sk.humanApproved ? .gray : .green)

                    Button("加一拍") {
                        store.updateChapter(chapterNumber) {
                            $0.skeleton?.beats.append(Beat())
                        }
                    }
                    .controlSize(.small)
                } else {
                    Spacer()
                    Text("尚无骨架——写前契约让每章有据可依")
                        .font(.caption).foregroundStyle(.tertiary)
                    Button("AI 搭骨架") {
                        Task { await vm.ai.runSkeleton(store: store, config: vm.config, chapter: chapterNumber, directive: "") }
                    }
                    .controlSize(.small)
                }
                Button {
                    withAnimation { collapsed = true }
                } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("收起骨架面板")
            }

            if let sk = skeleton {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(sk.beats) { beat in
                            beatCard(beat: beat)
                        }
                    }
                }
                HStack(spacing: 14) {
                    if !sk.endHook.isEmpty {
                        Label(sk.endHook, systemImage: "arrow.turn.down.right")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !sk.mustDeliver.isEmpty {
                        Label("硬交付：\(sk.mustDeliver.joined(separator: "；"))", systemImage: "checkmark.diamond")
                            .font(.caption).foregroundStyle(.blue)
                    }
                    if !sk.mustAvoid.isEmpty {
                        Label("禁止：\(sk.mustAvoid.joined(separator: "；"))", systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .zbGlass(cornerRadius: 0)
    }

    private func beatCard(beat: Beat) -> some View {
        BeatCardView(vm: vm, store: store, chapterNumber: chapterNumber, beat: beat)
    }
}

// MARK: - 单个骨架拍卡片（独立视图：保住结构同一性，编辑一拍不再全量重建）

struct BeatCardView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int
    let beat: Beat
    @State private var showScene = false
    @State private var confirmDeleteBeat = false

    private var current: Beat {
        store.chapter(chapterNumber)?.skeleton?.beats.first { $0.id == beat.id } ?? beat
    }

    private func update(_ change: (inout Beat) -> Void) {
        store.updateChapter(chapterNumber) { ch in
            guard var skt = ch.skeleton,
                  let idx = skt.beats.firstIndex(where: { $0.id == beat.id }) else { return }
            change(&skt.beats[idx])
            ch.skeleton = skt
        }
    }

    /// 场景层编辑器（popover）：卡片太窄放不下，且卡片变高会触发分栏约束再入崩溃
    private func sceneEditor(_ binding: Binding<Beat>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("场景层 ｜ 拍 \(beatIndex)").font(.headline)
            Text("连贯性审查（视角漂移、同一人分身两地）就靠这几个字段取证；AI 会填，你可以改。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            TextField("视角（这一拍贴着谁写）", text: binding.pov)
            TextField("地点", text: binding.location)
            TextField("时间标记（当夜／次日清晨…）", text: binding.timeLabel)
            TextField("在场人物（逗号分隔）", text: Binding(
                get: { current.cast.joined(separator: "，") },
                set: { newValue in
                    update { $0.cast = newValue.split(whereSeparator: { "，,、 ".contains($0) }).map(String.init) }
                }))
            TextField("转折（从什么变成什么）", text: binding.turn)
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
        .padding(14)
        .frame(width: 330)
    }

    private var beatIndex: Int {
        (store.chapter(chapterNumber)?.skeleton?.beats.firstIndex { $0.id == beat.id } ?? 0) + 1
    }

    var body: some View {
        let binding = Binding<Beat>(
            get: { current },
            set: { newValue in update { $0 = newValue } })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                let displayIndex = (store.chapter(chapterNumber)?.skeleton?.beats.firstIndex { $0.id == beat.id } ?? 0) + 1
                Text("拍 \(displayIndex)").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    update { $0.done.toggle() }
                } label: {
                    Image(systemName: current.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(current.done ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(current.done ? "标记这一拍未完成" : "标记这一拍完成")
                Button(role: .destructive) {
                    confirmDeleteBeat = true
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .accessibilityLabel("删除这一拍")
            }
            TextField("这个节点要发生什么", text: binding.summary, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            TextField("功能：推进/爽点/埋伏笔/收钩子/情绪", text: binding.purpose)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            HStack {
                TextField("字数", value: binding.suggestedWords, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .font(.caption)
                if !current.clueIDs.isEmpty {
                    Text(current.clueIDs.map { "[\($0)]" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            // 场景层：AI 会填，作者也必须能手改——连贯性审查（视角漂移 / 分身两地）全靠这几个字段取证。
            //
            // 这里必须走 popover、不能在卡片里展开：卡片一变高，外层横向 ScrollView 的高度跟着变，
            // 会撞上 SwiftUI 在 NavigationSplitView 里的约束更新再入（NSHostingView.SizeConstraints.update
            // → SplitViewChildController → 再进 setNeedsUpdateConstraints），实测直接 abort。
            // 顺带也治了 250pt 卡片塞 5 个输入框太挤的问题。
            Button {
                showScene = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                    Text("场景层").font(.caption2.bold())
                    Text("\(Int(current.sceneCompleteness * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(current.sceneCompleteness >= 0.5 ? Color.green : Color.orange)
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showScene, arrowEdge: .bottom, content: { sceneEditor(binding) })
            // 骨架填写：人在节拍上写草稿（渲染视图，不露 markdown 源码）
            RichProseEditor(
                markdown: Binding(
                    get: { current.draftText },
                    set: { newValue in update { $0.draftText = newValue } }),
                baseFont: NSFont.systemFont(ofSize: 12),
                textColor: NSColor.labelColor)
                .frame(width: 230, height: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.2)))
            HStack {
                Spacer()
                Button("合入正文") {
                    let text = current.draftText
                    guard !text.isEmpty else { return }
                    // 合入也是改正文：先留快照，失败就不动
                    let hasProse = !(store.chapter(chapterNumber)?.prose.isEmpty ?? true)
                    if hasProse, store.snapshotProse(chapter: chapterNumber, tag: "合入节拍前") == nil {
                        vm.showToast(store.lastSaveError ?? "合入失败：快照写入失败", success: false)
                        return
                    }
                    store.updateChapter(chapterNumber) { ch in
                        if !ch.prose.isEmpty { ch.prose += "\n\n" }
                        ch.prose += text
                        if var skt = ch.skeleton, let idx = skt.beats.firstIndex(where: { $0.id == beat.id }) {
                            skt.beats[idx].draftText = ""
                            ch.skeleton = skt
                        }
                        if ch.status == .empty || ch.status == .skeletoned { ch.status = .writing }
                    }
                    vm.showToast("节拍草稿已合入第\(chapterNumber)章正文")
                }
                .controlSize(.small)
                .disabled(current.draftText.isEmpty)
            }
        }
        .padding(8)
        .frame(width: 250)
        .zbGlass(cornerRadius: 8)
        .confirmationDialog("删除这一拍？", isPresented: $confirmDeleteBeat) {
            Button("删除", role: .destructive) {
                store.updateChapter(chapterNumber) { ch in
                    ch.skeleton?.beats.removeAll { $0.id == beat.id }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删骨架里的这一拍，不改动正文。")
        }
    }
}
