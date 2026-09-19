import SwiftUI

// MARK: - 工作区：三栏布局（导航 / 内容 / AI 协作面板）

/// 顶层导航（供状态条跨视图跳转）
enum WorkspaceSection: Hashable {
    case chapters
    case outline
    case clues
    case characters
    case canon
    case memory
    case inbox
    case graph
    case stats
}

struct ProjectWorkspaceView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore

    @AppStorage("focusMode") private var focusMode = false
    @State private var navVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: WorkspaceSection? = .chapters
    @State private var selectedChapter: Int?
    @State private var chapterPendingDelete: Int?
    @State private var exportMessage: String?
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView(columnVisibility: $navVisibility) {
            List(selection: $selection) {
                Section("写作") {
                    Label("章节", systemImage: "text.book.closed").tag(WorkspaceSection.chapters)
                }
                Section("规划") {
                    Label("大纲 · 时间线", systemImage: "timeline.selection").tag(WorkspaceSection.outline)
                    Label("人物卡", systemImage: "person.2").tag(WorkspaceSection.characters)
                    Label("伏笔台账", systemImage: "link").tag(WorkspaceSection.clues)
                    Label("设定", systemImage: "books.vertical").tag(WorkspaceSection.canon)
                }
                Section("数据") {
                    Label("写作统计", systemImage: "chart.bar.fill").tag(WorkspaceSection.stats)
                }
                Section("账房") {
                    Label("记忆中枢", systemImage: "brain").tag(WorkspaceSection.memory)
                    Label("记忆图谱", systemImage: "point.3.connected.trianglepath.dotted").tag(WorkspaceSection.graph)
                    Label("提案收件箱", systemImage: "tray.full").badge(pendingCount).tag(WorkspaceSection.inbox)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: ZBSpace.Column.min, ideal: ZBSpace.Column.ideal, max: ZBSpace.Column.max)
        } detail: {
            VStack(spacing: 0) {
                detailView
                AgentStatusStrip(vm: vm, store: store) {
                    selection = .inbox
                }
            }
        }
        .navigationTitle(store.project.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { searchButton }
            ToolbarItem(placement: .primaryAction) { exportMenu }
            ToolbarItem(placement: .primaryAction) { importButton }
            ToolbarItem(placement: .primaryAction) { saveButton }
            ToolbarItem(placement: .primaryAction) { appearanceButton }
            ToolbarItem(placement: .primaryAction) { backButton }
        }
        .alert("导出完成", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(exportMessage ?? "")
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(vm: vm, store: store, onSelectChapter: { n in
                selectedChapter = n
                selection = .chapters
                if focusMode { focusMode = false }
            }, onSelectSection: { sec in
                vm.navigateToSection = sec
                if focusMode { focusMode = false }
            })
        }
        .onChange(of: focusMode) { focused in
            withAnimation(.snappy(duration: 0.3)) {
                navVisibility = focused ? .detailOnly : .all
            }
        }
        .onChange(of: vm.navigateToSection) { section in
            if let section {
                selection = section
                vm.navigateToSection = nil
            }
        }
        .onAppear {
            if selectedChapter == nil {
                selectedChapter = (store.chapters.last { !$0.prose.isEmpty } ?? store.chapters.last)?.number
            }
            if selection == nil { selection = .chapters }
            if focusMode { navVisibility = .detailOnly }
        }
    }

    private var pendingCount: Int {
        let n = store.proposals.filter { $0.status == .pending }.count
        return n > 0 ? n : 0
    }

    private var subtitle: String {
        let drafted = store.chapters.filter { !$0.prose.isEmpty }.count
        let words = store.chapters.reduce(0) { $0 + $1.wordCount }
        return "\(drafted) 章成稿 · 共 \(words) 字"
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .chapters, nil:
            chapterWorkspace
        case .outline:
            OutlineView(vm: vm, store: store)
        case .clues:
            ClueBoardView(vm: vm, store: store)
        case .characters:
            CharactersView(store: store)
        case .memory:
            MemoryView(store: store)
        case .canon:
            CanonView(store: store)
        case .inbox:
            ProposalInboxView(vm: vm, store: store)
        case .graph:
            MemoryGraphView(vm: vm, store: store) { n in
                selectedChapter = n
                selection = .chapters
                if focusMode { focusMode = false }
            }
        case .stats:
            StatsView(store: store)
        }
    }

    private var chapterWorkspace: some View {
        HSplitView {
            VStack(spacing: 0) {
                ScrollView {
                    ForEach(store.chapters) { ch in
                        chapterRow(ch)
                    }
                }
                Button {
                    let n = (store.chapters.map(\.number).max() ?? 0) + 1
                    _ = store.ensureChapter(n)
                    selectedChapter = n
                } label: {
                    Label("添加章节", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 8)
            }
            .frame(minWidth: focusMode ? 0 : 190,
                   idealWidth: focusMode ? 0 : 215,
                   maxWidth: focusMode ? 0 : 300,
                   maxHeight: .infinity)
            .opacity(focusMode ? 0 : 1)

            Group {
                if let n = selectedChapter, store.chapter(n) != nil {
                    ChapterEditorView(vm: vm, store: store, chapterNumber: n)
                        .id(n)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "text.book.closed").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("选择或新建一个章节").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chapterRow(_ ch: Chapter) -> some View {
        let isSelected = selectedChapter == ch.number
        return HStack(spacing: 8) {
            Text("\(ch.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(ch.title.isEmpty ? "第\(ch.number)章" : ch.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(statusLine(ch))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : statusColor(ch.status))
            }
            Spacer()
            if ch.wordCount > 0 {
                Text("\(ch.wordCount)字")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 6)
        .onTapGesture { selectedChapter = ch.number }
        .contextMenu {
            Button("删除本章…", role: .destructive) { chapterPendingDelete = ch.number }
        }
        .confirmationDialog("删除第\(ch.number)章？", isPresented: Binding(
            get: { chapterPendingDelete == ch.number },
            set: { if !$0 { chapterPendingDelete = nil } })) {
            Button("删除（含快照，不可恢复）", role: .destructive) {
                if selectedChapter == ch.number { selectedChapter = nil }
                store.deleteChapter(ch.number)
                chapterPendingDelete = nil
            }
        } message: {
            Text("将删除本章正文、骨架与全部快照。时间线中本章的事件会一并清除。")
        }
    }

    private func statusLine(_ ch: Chapter) -> String {
        var parts = [ch.status.rawValue]
        if let sk = ch.skeleton, !sk.beats.isEmpty {
            let done = sk.beats.filter(\.done).count
            parts.append("骨架 \(done)/\(sk.beats.count) 拍")
        }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ s: ChapterStatus) -> Color {
        switch s {
        case .empty: return .secondary
        case .skeletoned: return .indigo
        case .writing: return .orange
        case .written: return .blue
        case .checked: return .teal
        case .polished: return .green
        case .done: return .gray
        }
    }

    private var searchButton: some View {
        Button {
            showSearch = true
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .help("全书搜索（⌘⇧G）")
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .accessibilityLabel("全书搜索")
    }

    @ViewBuilder
    private var exportMenu: some View {
        Menu {
            Button("合并稿（单文件）") { exportMessage = vm.exportManuscript() }
            Button("oh-story 目录（大纲/设定/正文/追踪）") { exportMessage = vm.exportOhStory() }
            Button("分卷 TXT（每 20 章一卷）") { exportMessage = vm.exportVolumeTxt() }
        } label: {
            Image(systemName: "square.and.arrow.up.on.square")
        }
        .help("导出")
        .accessibilityLabel("导出")
    }

    private var importButton: some View {
        Button {
            vm.requestImportViaPanel = true
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .help("导入已有大纲 / 设定 / 正文")
        .accessibilityLabel("导入")
    }

    private var saveButton: some View {
        Button {
            do {
                try store.saveNow()
                store.lastSaveError = nil
                exportMessage = "已保存《\(store.project.title)》"
            } catch {
                store.lastSaveError = "保存失败：\(error.localizedDescription)"
            }
        } label: {
            Image(systemName: "checkmark.circle")
        }
        .help("保存（⌘S）")
        .keyboardShortcut("s", modifiers: .command)
        .accessibilityLabel("保存")
    }

    private var appearanceButton: some View {
        Button {
            vm.cycleAppearance()
        } label: {
            Image(systemName: vm.appearanceMode.icon)
        }
        .help("外观：\(vm.appearanceMode.rawValue)（点击切换）")
        .accessibilityLabel("切换外观，当前\(vm.appearanceMode.rawValue)")
    }

    private var backButton: some View {
        Button(role: .destructive) {
            vm.closeProject()
        } label: {
            Image(systemName: "chevron.left")
        }
        .help("回到书架")
        .accessibilityLabel("回到书架")
    }
}

// MARK: - AI 状态条（运行中流式预览；完成后给"查看提案"直达；错误给"打开设置"）

struct AgentStatusStrip: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let goToInbox: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if vm.ai.running {
                runningStrip
            } else if let n = vm.ai.lastRunNewProposals, n > 0 {
                doneStrip(n)
            }
            if let err = vm.ai.lastError {
                errorStrip(err)
            }
            if let saveErr = store.lastSaveError {
                HStack {
                    Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
                    Text(saveErr).font(.caption)
                    Spacer()
                }
                .padding(ZBSpace.sm)
                .background(Color.red.opacity(0.1))
            }
        }
    }

    private var runningStrip: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 正在处理：\(vm.ai.runningCapability?.rawValue ?? "")（产出将进入提案收件箱，等作者确认）")
                    .font(.caption).bold()
                if !vm.ai.lastToolLog.isEmpty {
                    Text(vm.ai.lastToolLog.suffix(3).joined(separator: "\n"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(vm.ai.streamPreview.isEmpty ? "…" : vm.ai.streamPreview)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(4)
            }
            Spacer()
        }
        .padding(ZBSpace.sm)
        .background(Color.accentColor.opacity(0.06))
    }

    private func doneStrip(_ n: Int) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("AI 已完成，新登记 \(n) 条提案等你裁决。")
                .font(.caption)
            Button("查看提案") {
                goToInbox()
                vm.ai.lastRunNewProposals = nil
            }
            .controlSize(.small)
            Spacer()
            Button {
                vm.ai.lastRunNewProposals = nil
            } label: { Image(systemName: "xmark") }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(ZBSpace.sm)
        .background(Color.green.opacity(0.08))
    }

    private func errorStrip(_ err: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(err).font(.caption)
            if err.contains("API Key") {
                SettingsLink {
                    Text("打开设置").font(.caption)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            Spacer()
            Button {
                vm.ai.lastError = nil
            } label: { Image(systemName: "xmark") }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
    }
}
