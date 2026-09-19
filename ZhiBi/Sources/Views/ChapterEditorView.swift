import SwiftUI

/// 章节编辑器：上=骨架（AI 提案→人改→人批），下=正文（人亲笔）。
/// 工具栏五个动作全部产出提案或报告，没有任何"AI 代写"入口。
struct ChapterEditorView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int

    @State private var directive = ""
    @State private var showSkeletonEditor = true
    @State private var beatDraftFor: UUID?
    @State private var lintResult: LintSummary?
    @State private var newNote = ""
    @State private var showSnapshots = false
    @State private var showRecall = false
    @State private var showPipeline = false
    @State private var showInbox = false
    @State private var bannerDismissed = false

    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("dailyGoal") private var dailyGoal = 2000

    @AppStorage("proseCentered") private var proseCentered = true
    @AppStorage("proseSerif") private var proseSerif = false
    @AppStorage("proseFontSize") private var proseFontSize = 15.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chapter: Chapter { store.chapter(chapterNumber) ?? Chapter(number: chapterNumber) }

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
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3), value: showSkeletonEditor)
        .onAppear { store.autoSaveEnabled = vm.config.autoSave }
        .sheet(isPresented: $showSnapshots) {
            SnapshotBrowser(store: store, chapterNumber: chapterNumber)
        }
        .sheet(isPresented: $showRecall) {
            RecallSheetView(vm: vm, store: store, chapterNumber: chapterNumber, directive: directive)
        }
        .sheet(isPresented: $showPipeline) {
            PipelineSheet(vm: vm, store: store, chapterNumber: chapterNumber)
        }
        .sheet(isPresented: $showInbox) {
            ProposalInboxView(vm: vm, store: store)
                .frame(minWidth: 620, minHeight: 480)
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
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .help("流水线：主线→骨架→写作→审查→修复→记忆/文风审查（⌘⇧W）")

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
                Button {
                    Task { await vm.ai.runClueInventory(store: store, config: vm.config, scope: "") }
                } label: {
                    Label("AI 盘点伏笔（全书）", systemImage: "link")
                }
                Divider()
                Button {
                    _ = store.snapshotProse(chapter: chapterNumber, tag: "手动")
                } label: {
                    Label("保存快照", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    if let latest = store.snapshots(chapter: chapterNumber).first {
                        store.restoreSnapshot(chapter: chapterNumber, name: latest.name)
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
                Task { await vm.ai.runSkeleton(store: store, config: vm.config, chapter: chapterNumber, directive: directive) }
            } label: {
                Label("搭骨架", systemImage: "bone")
            }
            .disabled(vm.ai.running)
            .help("AI 提出本章骨架提案，由你修改批准；正文由你亲笔完成")

            Button {
                Task { await vm.ai.runValidation(store: store, config: vm.config, chapter: chapterNumber) }
            } label: {
                Label("验证", systemImage: "checkmark.seal")
            }
            .disabled(vm.ai.running)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .help("一键验证：确定性体检 + AI 五类客观错误审校（⌘⇧V）")

            Button {
                Task { await vm.ai.runDeslop(store: store, config: vm.config, chapter: chapterNumber) }
            } label: {
                Label("去AI味", systemImage: "sparkles")
            }
            .disabled(vm.ai.running)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("去AI味：本地扫描 + 逐处修改建议（⌘⇧D）")
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
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(ZB.vermillion.opacity(0.06))
            }
        }
    }

    // MARK: 正文编辑器（人的领地）

    private var proseEditor: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("正文（你亲笔）").font(.caption.bold()).foregroundStyle(.secondary)
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
            .padding(10)
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
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int
    @Environment(\.dismiss) private var dismiss
    @State private var preview: (name: String, text: String)?
    @State private var snapshots: [(name: String, text: String)] = []

    var body: some View {
        HStack(spacing: 0) {
            List {
                ForEach(snapshots, id: \.name) { snap in
                    HStack {
                        Text(snap.name).font(.caption.monospaced())
                        Spacer()
                        Button("预览") { preview = snap }.controlSize(.small)
                        Button("回滚到此版本", role: .destructive) {
                            store.restoreSnapshot(chapter: chapterNumber, name: snap.name)
                            dismiss()
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
        BeatCardView(store: store, chapterNumber: chapterNumber, beat: beat)
    }
}

// MARK: - 单个骨架拍卡片（独立视图：保住结构同一性，编辑一拍不再全量重建）

struct BeatCardView: View {
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int
    let beat: Beat

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
                Button(role: .destructive) {
                    store.updateChapter(chapterNumber) { ch in
                        ch.skeleton?.beats.removeAll { $0.id == beat.id }
                    }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
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
                    store.updateChapter(chapterNumber) { ch in
                        if !ch.prose.isEmpty { ch.prose += "\n\n" }
                        ch.prose += text
                        if var skt = ch.skeleton, let idx = skt.beats.firstIndex(where: { $0.id == beat.id }) {
                            skt.beats[idx].draftText = ""
                            ch.skeleton = skt
                        }
                        if ch.status == .empty || ch.status == .skeletoned { ch.status = .writing }
                    }
                }
                .controlSize(.small)
                .disabled(current.draftText.isEmpty)
            }
        }
        .padding(8)
        .frame(width: 250)
        .zbGlass(cornerRadius: 8)
    }
}
