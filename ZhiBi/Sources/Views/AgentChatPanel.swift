import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 右侧 AI 协作面板：对话 / 轨迹双窗
//
// 对话是作者与编辑搭档的常驻入口；轨迹仍然保留完整工具调用、结果与流式输出。
// 两者共用 AIService 的运行态：同一时间只跑一个 AI 任务，避免并发改同一本书。

struct AgentRightPanel: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    @ObservedObject var ai: AIService
    let onClose: () -> Void
    let onOpenInbox: () -> Void
    let onOpenChapter: (Int, String?) -> Void
    let onOpenSection: (WorkspaceSection) -> Void

    @AppStorage("agentRightPanelTab") private var tab = "chat"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZBSpace.xs) {
                Picker("", selection: $tab) {
                    Text("对话").tag("chat")
                    Text("轨迹").tag("trail")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
                .labelsHidden()
                Spacer()
                if ai.running {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("收起 AI 协作面板（⌘⇧J）")
            }
            .padding(.horizontal, ZBSpace.sm)
            .padding(.vertical, ZBSpace.xs + 2)
            Divider()
            if tab == "trail" {
                AgentTrajectoryPanel(ai: ai, onClose: onClose, showsCloseButton: false)
            } else {
                AgentChatPanel(vm: vm, store: store, ai: ai, onOpenInbox: onOpenInbox,
                               onOpenChapter: onOpenChapter, onOpenSection: onOpenSection)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: vm.chatInvocation?.token) { _, token in
            if token != nil { tab = "chat" }
        }
        .onAppear {
            if vm.chatInvocation != nil { tab = "chat" }
        }
    }
}

// MARK: - 对话窗

struct AgentChatPanel: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    @ObservedObject var ai: AIService
    let onOpenInbox: () -> Void
    let onOpenChapter: (Int, String?) -> Void
    let onOpenSection: (WorkspaceSection) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var confirmClear = false
    @State private var confirmArchive = false
    @State private var archiveNote: String?
    @State private var showArchives = false
    @State private var targetChapter: Int?
    @FocusState private var inputFocused: Bool

    /// 选中的对话目标章必须真的属于当前这本书；切换作品后，旧书的章号不能继续生效。
    private var activeChapter: Int {
        guard let targetChapter else { return store.currentChapter }
        if targetChapter == store.currentChapter || store.chapter(targetChapter) != nil {
            return targetChapter
        }
        return store.currentChapter
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ai.running
    }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            if let n = ai.lastChatNewProposals, n > 0, !ai.chatStreaming {
                proposalBanner(n)
            }
            Divider()
            composer
        }
        .confirmationDialog("清空与 AI 的对话记录？", isPresented: $confirmClear) {
            Button("清空（不可撤销）", role: .destructive) {
                store.clearChat()
                ai.chatError = nil
                ai.lastChatNewProposals = nil
                archiveNote = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除对话历史，不影响正文、设定和提案。")
        }
        .confirmationDialog("归档并清空与 AI 的对话？", isPresented: $confirmArchive) {
            Button("归档到项目并清空", role: .destructive) {
                if let url = store.archiveChat() {
                    archiveNote = "已归档：\(url.lastPathComponent)"
                    ai.chatError = nil
                    ai.lastChatNewProposals = nil
                } else {
                    ai.chatError = store.lastSaveError ?? "归档失败：没有可写入的对话。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会在作品目录写入 chat-archive-<时间>.md，然后清空对话。正文、设定和提案不受影响。")
        }
        .sheet(isPresented: $showArchives) {
            ChatArchiveSheet(store: store)
        }
        .onChange(of: store.rootURL) { _, _ in
            // 换书后旧的目标章/草稿不能带进新书；流式状态由 AppViewModel 清理。
            targetChapter = store.currentChapter
            draft = ""
            confirmClear = false
            confirmArchive = false
            archiveNote = nil
            showArchives = false
        }
        .onChange(of: vm.chatInvocation?.token) { _, _ in
            consumeInvocation()
        }
        .onAppear {
            if targetChapter == nil { targetChapter = store.currentChapter }
            consumeInvocation()
            inputFocused = true
        }
    }

    // MARK: 消息区

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ZBSpace.sm + 2) {
                    if store.chatMessages.isEmpty && !ai.chatStreaming {
                        emptyState
                    }
                    ForEach(store.chatMessages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if ai.chatStreaming {
                        streamingBubble
                            .id("chat-streaming")
                    }
                    if let error = ai.chatError, !error.isEmpty, !ai.chatStreaming {
                        errorBanner(error)
                    }
                    Color.clear.frame(height: 1).id("chat-tail")
                }
                .padding(ZBSpace.sm)
            }
            .onChange(of: store.chatMessages.last?.id) { _, _ in
                withAnimation(ZBMotion.standard(reduceMotion: reduceMotion)) {
                    proxy.scrollTo("chat-tail", anchor: .bottom)
                }
            }
            .onChange(of: ai.chatStream) { _, _ in
                guard ai.chatStreaming else { return }
                proxy.scrollTo("chat-tail", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("chat-tail", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(Color.accentColor)
                Text("问这本书的任何事").font(.headline)
            }
            Text("我会先查正文、设定、档案卡、伏笔和时间线，再回答并标出来源。需要改书或写整章草稿时只会登记提案；你审查、修改、采纳后才进正文。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("试试：").font(.caption2.bold()).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 6) {
                quickPrompt("总结目前进度，并指出最该先处理的三件事")
                quickPrompt("查一下最新一章有没有和前面设定冲突")
                quickPrompt("现在哪条伏笔最久没推进？该怎么回收？")
                quickPrompt("按现有骨架写下一章草稿，先提交提案给我审")
                quickPrompt("读一下最新草稿，按我的意见改一版提案")
                quickPrompt("对照本章骨架检查最新草稿有没有漏拍或偏移")
            }
        }
        .padding(.top, ZBSpace.lg)
    }

    private func quickPrompt(_ text: String) -> some View {
        Button {
            send(text)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.caption2)
                Text(text).font(.caption).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(ai.running)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 5) {
                if !isUser {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor)
                }
                Text(isUser ? "你" : "AI 搭档")
                    .font(.caption2.bold())
                    .foregroundStyle(isUser ? .secondary : Color.accentColor)
                if !isUser {
                    Text(message.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Group {
                if isUser {
                    Text(message.text)
                } else {
                    renderedAssistantText(message.text)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isUser ? Color.accentColor.opacity(0.13)
                               : (message.isError ? Color.red.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
            .foregroundStyle(message.isError ? Color.red : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contextMenu {
                Button("复制这条消息") { copy(message.text) }
            }
            if !message.citations.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4, alignment: .leading)],
                          alignment: .leading, spacing: 4) {
                    ForEach(message.citations.prefix(8), id: \.self) { citation in
                        if let target = KnowledgeCitations.target(for: citation) {
                            Button {
                                open(target)
                            } label: {
                                ZBChip(text: citation, color: .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("前往 \(citation) 核对原文")
                        } else {
                            ZBChip(text: citation, color: .secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// 对话回答常带 markdown（加粗/行内代码/列表）。渲染失败就退回纯文本，绝不吞内容。
    private func renderedAssistantText(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func open(_ target: KnowledgeCitationTarget) {
        switch target {
        case .chapter(let n):
            // 来源芯片只带出处，不带原文句；编辑器会打开该章，不强行定位。
            onOpenChapter(n, nil)
        case .canon:
            onOpenSection(.canon)
        case .clues:
            onOpenSection(.clues)
        case .memory:
            onOpenSection(.memory)
        case .outline:
            onOpenSection(.outline)
        }
    }

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor)
                Text("AI 搭档").font(.caption2.bold()).foregroundStyle(Color.accentColor)
                ProgressView().controlSize(.mini)
            }
            if ai.chatStream.isEmpty {
                Text("正在查资料并组织回答…")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text(ai.chatStream)
                    .font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func proposalBanner(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full").foregroundStyle(.orange)
            Text("本次对话登记了 \(count) 条提案，待你审查。")
                .font(.caption)
            Spacer()
            Button("去收件箱") { onOpenInbox() }
                .controlSize(.mini)
        }
        .padding(.horizontal, ZBSpace.sm)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !ai.running, store.chatMessages.contains(where: { $0.role == .user }) {
                Button("重试") {
                    Task { await ai.retryLastChat(store: store, config: vm.config, chapter: activeChapter) }
                }
                .controlSize(.mini)
            }
            Button("知道了") { ai.chatError = nil }
                .controlSize(.mini)
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 7) {
                TextField("问 AI：查设定、找伏笔、看下一步…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit { send() }
                    .disabled(ai.running)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .help("发送（回车）")
            }
            HStack(spacing: 6) {
                if ai.running && !ai.chatStreaming {
                    Text("其他 AI 任务运行中，完成后再问。")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("对话针对").font(.caption2).foregroundStyle(.tertiary)
                    Menu {
                        Button("当前写作章（第\(store.currentChapter)章）") {
                            targetChapter = store.currentChapter
                        }
                        if !store.chapters.isEmpty { Divider() }
                        ForEach(store.chapters.sorted { $0.number < $1.number }) { ch in
                            Button("第\(ch.number)章 \(ch.title)") { targetChapter = ch.number }
                        }
                    } label: {
                        Text("第\(activeChapter)章")
                            .font(.caption2.bold())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("切换对话针对的章节；写草稿/读草稿都会跟随这一章")
                    Text("· AI 只能提案，采纳后才进正文。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let archiveNote {
                    Text(archiveNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if ai.chatStreaming {
                    Button("停止") { ai.cancelCurrentRun() }
                        .controlSize(.mini)
                        .foregroundStyle(.orange)
                } else if !ai.running, store.chatMessages.last?.role == .assistant {
                    Button {
                        Task { await ai.regenerateLastChat(store: store, config: vm.config, chapter: activeChapter) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                    .help("重新回答上一问（替换上一条回复；可能新增提案）")
                }
                Menu {
                    Button("导出对话为 Markdown…") { exportChat() }
                        .disabled(store.chatMessages.isEmpty)
                    Button("归档到项目并清空…") { confirmArchive = true }
                        .disabled(store.chatMessages.isEmpty || ai.running)
                    Divider()
                    Button("查看归档…") { showArchives = true }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.mini)
                .help("导出或归档对话记录")
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .disabled(store.chatMessages.isEmpty || ai.running)
                .help("清空对话记录")
            }
        }
        .padding(ZBSpace.sm)
    }

    /// 资料库等外部入口送来的提示词：填进输入框、切到对应章，然后消费掉请求。
    private func consumeInvocation() {
        guard let invocation = vm.chatInvocation else { return }
        draft = invocation.prompt
        if let chapter = invocation.chapter {
            targetChapter = chapter
        }
        vm.chatInvocation = nil
        archiveNote = nil
        inputFocused = true
    }

    private func send(_ text: String? = nil) {
        let outbound = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outbound.isEmpty, !ai.running else { return }
        if text == nil { draft = "" }
        ai.chatError = nil
        archiveNote = nil
        inputFocused = true
        Task { await ai.sendChat(store: store, config: vm.config, text: outbound, chapter: activeChapter) }
    }

    private func exportChat() {
        let panel = NSSavePanel()
        panel.title = "导出与 AI 的对话记录"
        panel.nameFieldStringValue = ChatTranscript.fileName(projectTitle: store.project.title)
        // UTType.markdown 的可用性标注比部署目标新，用扩展名构造更稳。
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportChat(to: url)
            archiveNote = "已导出：\(url.lastPathComponent)"
        } catch {
            ai.chatError = "导出失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 对话归档浏览

struct ChatArchiveSheet: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ChatArchiveEntry] = []
    @State private var selection: Set<URL> = []
    @State private var query = ""
    @State private var preview = ""
    @State private var deleteURLs: Set<URL> = []
    @State private var canRestore = false
    @State private var restoreURL: URL?
    @State private var restoreCount = 0
    @State private var confirmDelete = false
    @State private var confirmRestore = false
    @State private var note: String?

    private var visibleEntries: [ChatArchiveEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.matches(query: q) }
    }

    private var singleSelection: URL? {
        selection.count == 1 ? selection.first : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear { reload() }
        .onChange(of: selection) { _, _ in updatePreview() }
        .onChange(of: query) { _, _ in
            let visible = Set(visibleEntries.map(\.url))
            selection = selection.intersection(visible)
        }
        .confirmationDialog("删除选中的对话归档？", isPresented: $confirmDelete) {
            Button("删除 \(deleteURLs.count) 份", role: .destructive) {
                let n = store.deleteChatArchives(Array(deleteURLs))
                note = "已删除 \(n) 份归档"
                deleteURLs.removeAll()
                selection.removeAll()
                reload()
            }
            Button("取消", role: .cancel) { deleteURLs.removeAll() }
        } message: {
            Text("只删除归档文件（连同可恢复 JSON），不影响当前对话、正文和提案。")
        }
        .confirmationDialog("恢复这份归档到当前对话？", isPresented: $confirmRestore) {
            Button("恢复 \(restoreCount) 条消息") {
                if let url = restoreURL, let count = store.restoreChatArchive(url) {
                    note = "已恢复 \(count) 条消息到当前对话"
                } else {
                    note = "恢复失败：归档缺少可恢复快照"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会在当前对话末尾追加这些消息，不删除现有对话，也不会重新登记归档里的提案。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").foregroundStyle(Color.accentColor)
            Text("对话归档").font(.headline)
            Text("\(visibleEntries.count)/\(entries.count) 份")
                .font(.caption).foregroundStyle(.secondary)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.green).lineLimit(1)
            }
            Spacer()
            Button("恢复到当前对话") {
                guard let url = singleSelection,
                      let payload = store.readChatArchivePayload(url) else { return }
                restoreURL = url
                restoreCount = payload.messages.count
                confirmRestore = true
            }
            .controlSize(.small)
            .disabled(!canRestore)
            .help(canRestore ? "把归档消息追加到当前对话（不重新登记提案）" : "选中一份带 JSON 快照的归档才能恢复")
            Button("在访达中显示") {
                if let url = singleSelection {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .controlSize(.small)
            .disabled(singleSelection == nil)
            Button("删除所选…", role: .destructive) {
                deleteURLs = selection
                confirmDelete = true
            }
            .controlSize(.small)
            .disabled(selection.isEmpty)
            Button("完成") { dismiss() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("筛选归档（文件名 / 日期 / 大小）", text: $query)
                .textFieldStyle(.roundedBorder)
            if !query.isEmpty {
                Button("清除") { query = "" }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "archivebox").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("还没有对话归档").font(.headline)
                Text("在对话窗的导出菜单里点「归档到项目并清空」，这里就会出现可回看、可恢复的记录。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else if visibleEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("没有匹配的归档").font(.headline)
                Text("换个文件名、日期或大小试试。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            HSplitView {
                List(selection: $selection) {
                    ForEach(visibleEntries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                                .font(.callout)
                                .lineLimit(1)
                            Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.sizeLabel)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(entry.url)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 240, idealWidth: 290)

                ScrollView {
                    Text(preview.isEmpty ? "选择左侧归档查看内容；按住 ⌘ 可多选。" : preview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
    }

    private func reload() {
        entries = store.listChatArchives()
        let existing = Set(entries.map(\.url))
        selection = selection.intersection(existing)
        if selection.isEmpty, let first = entries.first?.url {
            selection = [first]
        }
        updatePreview()
    }

    private func updatePreview() {
        if selection.count == 1, let url = selection.first {
            loadPreview(url)
        } else {
            preview = selection.isEmpty ? "" : "已选 \(selection.count) 份归档"
            canRestore = false
        }
    }

    private func loadPreview(_ url: URL?) {
        guard let url else {
            preview = ""
            canRestore = false
            return
        }
        preview = store.readChatArchive(url) ?? "（读取失败：文件可能已被移动或删除）"
        canRestore = store.chatArchivePayloadURL(for: url) != nil
    }
}
