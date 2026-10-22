import SwiftUI

// MARK: - AI 工具箱：拆书 / 整理旧稿 / 封面提案 / 短篇成稿（对标 story-long-analyze /
// story-import 的「整理三类资料」/ story-cover / story-short-write）
//
// 运行语义分两类：
// - 拆书 / 封面提案：纯文本产出（runTextOnly 通道），结果就地展示 + 一键存为备忘提案
// - 设定归类 / 整理旧稿 / 短篇成稿：产出就地过目 + 一键采纳（提案仍在收件箱留痕，铁律不变）

struct AIToolboxSheet: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    @ObservedObject var ai: AIService
    let chapterNumber: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tool: String, CaseIterable, Identifiable {
        var id: String { rawValue }

        case canonClassify = "设定归类"
        case analyze = "拆书"
        case organize = "整理旧稿"
        case coverSVG = "封面绘制"
        case shortStory = "短篇成稿"

        var icon: String {
            switch self {
            case .canonClassify: return "square.grid.3x3.square"
            case .analyze: return "text.magnifyingglass"
            case .organize: return "tray.and.arrow.down"
            case .coverSVG: return "photo.artframe"
            case .shortStory: return "doc.richtext"
            }
        }

        var intro: String {
            switch self {
            case .analyze: return "贴一段参考文本（建议前 3 章），AI 从钩子/冲突/悬念/节奏四维拆解，每个判断给出原文位置。学结构，不抄情节。"
            case .canonClassify: return "AI 读全部设定文档，逐篇给出分类（世界观/势力人物/修炼体系/剧情大纲/题材规则）与规范改名建议。采纳后设定页按类别分组。"
            case .organize: return "正文有了、账本还没建？AI 把散在各章的信息整理成三类资料：设定与人物 / 剧情时间线 / 伏笔追踪——作者核对后再续写。"
            case .coverSVG: return "AI 直接绘制 SVG 封面（书名/署名/装饰一次成形）。预览满意点「采用为本书封面」，书架即用。"
            case .shortStory: return "围绕一个核心冲突写短篇：起冲突/推转折/落结局。产出大纲+全文一份草稿提案，走既有审查采纳流程。"
            }
        }
    }

    @State private var tool: Tool = .analyze
    // 拆书
    @State private var referenceText = ""
    @State private var analyzeFocus = ""
    // 封面
    @State private var coverAuthor = ""
    @State private var coverMood = ""
    @State private var coverDirection = ""
    @State private var coverSVGCode = ""
    @State private var adopted = false
    // 短篇
    @State private var shortConflict = ""
    @State private var shortWords = 6000
    // 运行结果（纯文本类）
    @State private var resultText = ""
    @State private var savedAsProposal = false
    @State private var copiedText = false
    @State private var copiedSVG = false
    /// sheet 内的就地反馈：全局 toast 会被弹窗盖住
    @State private var localNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ZBSpace.sm) {
            HStack {
                Text("AI 工具箱").font(.headline)
                Picker("", selection: $tool) {
                    ForEach(Tool.allCases) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 运行中禁止切工具：否则本次产出会被清掉/错挂到另一个工具下
                .disabled(ai.running)
                Spacer()
                if ai.running {
                    ProgressView().controlSize(.small)
                }
            }

            Text(tool.intro)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            inputSection

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(runLabel) { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(ai.running || !inputReady)
            }
        }
        .padding(ZBSpace.lg)
        .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 560)

        // 结果区用 safeAreaInset 而不是 overlay：overlay 会压在输入区与底部按钮上
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ai.running || !resultText.isEmpty || ai.lastError != nil || !ai.lastToolLog.isEmpty || localNote != nil {
                resultFooter
                    .padding(.horizontal, ZBSpace.lg)
                    .padding(.bottom, ZBSpace.sm)
                    .background(.regularMaterial)
            }
        }
        // 切换工具时清掉上一轮结果：否则「整理旧稿」的提案会被当成「短篇成稿」的产出展示
        .onChange(of: tool) { _ in
            resultText = ""
            coverSVGCode = ""
            adopted = false
            savedAsProposal = false
            localNote = nil
            ai.lastRunNewProposals = nil
            ai.lastRunProposalIDs = []
        }
    }

    private var runLabel: String {
        switch tool {
        case .canonClassify: return "开始归类"
        case .analyze: return "拆解"
        case .organize: return "整理成三类资料"
        case .coverSVG: return "绘制封面"
        case .shortStory: return "写短篇草稿"
        }
    }

    private var inputReady: Bool {
        switch tool {
        case .canonClassify: return !store.canonSections.isEmpty
        case .analyze: return referenceText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50
        case .organize: return store.chapters.contains { !$0.prose.isEmpty }
        case .coverSVG: return true
        case .shortStory: return !shortConflict.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private var inputSection: some View {
        switch tool {
        case .canonClassify:
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                Label("将归类 \(store.canonSections.count) 篇设定文档", systemImage: "square.grid.3x3.square")
                    .font(.caption)
                if store.canonSections.isEmpty {
                    Text("还没有设定文档。").font(.caption).foregroundStyle(.orange)
                }
                Text("产出走提案通道：每篇 → 类别（可附带规范改名）。采纳后设定页按类别分组。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .analyze:
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                Text("参考文本（\(referenceText.count) 字，建议 ≥ 1000）")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $referenceText)
                    .font(.callout)
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                TextField("拆解重点（可选，如：只拆前三段的开篇钩子）", text: $analyzeFocus)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }
        case .organize:
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                let drafted = store.chapters.filter { !$0.prose.isEmpty }
                Label("将扫描 \(drafted.count) 章正文（\(drafted.reduce(0) { $0 + $1.wordCount }) 字）",
                      systemImage: "book.closed")
                    .font(.caption)
                if drafted.isEmpty {
                    Text("还没有正文——先写或导入正文再整理。").font(.caption).foregroundStyle(.orange)
                }
                Label("产出走提案通道：设定与人物（canon）/ 伏笔追踪（clues）/ 剧情时间线（备忘），共约 3-5 条提案。"
                      + "正文没写明的设定 AI 会列为「待作者确认」，不会编。", systemImage: "checkmark.seal")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .coverSVG:
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                Text("书名《\(store.project.title)》｜题材：\(store.project.genre.isEmpty ? "（未定）" : store.project.genre)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("署名（可空）", text: $coverAuthor)
                    .textFieldStyle(.roundedBorder)
                TextField("氛围要求（如：压迫感、冷色调、史诗）", text: $coverMood)
                    .textFieldStyle(.roundedBorder)
                TextField("画面方向（如：少年背影 + 断刀 + 雨夜；避免：剧透画面）", text: $coverDirection)
                    .textFieldStyle(.roundedBorder)
                Text("产出为 SVG 代码，应用内直接渲染。预览满意点「采用为本书封面」。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .shortStory:
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                TextEditor(text: $shortConflict)
                    .font(.callout)
                    .frame(minHeight: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("核心冲突")
                if shortConflict.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("核心冲突示例：姐姐要卖老宅，弟弟发现钥匙留给了一个陌生人。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Stepper("目标篇幅：约 \(shortWords) 字", value: $shortWords, in: 2000...20000, step: 1000)
                    .font(.caption)
                if let ch = store.chapter(chapterNumber), !ch.prose.isEmpty {
                    Label("将占用第\(chapterNumber)章的草稿提案位（现有正文会先自动快照，采纳才覆盖）",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var resultFooter: some View {
        VStack(alignment: .leading, spacing: ZBSpace.xs) {
            Divider()
            if let note = localNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if let err = ai.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if ai.running {
                ForEach(ai.lastToolLog.suffix(2), id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if tool == .coverSVG, !coverSVGCode.isEmpty {
                // SVG 实时预览（600x800 缩到 180x240）+ 采用
                HStack(alignment: .top, spacing: ZBSpace.sm) {
                    SVGCoverLayer(image: previewImage)
                        .frame(width: 180, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ZB.hairline))
                    VStack(alignment: .leading, spacing: ZBSpace.xs) {
                        Text("预览（600×800）").font(.caption).foregroundStyle(.secondary)
                        Text("满意就采用——书架网格/列表立即换上这张封面；不满意可改氛围/画面再绘制一次。")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(adopted ? "已是本书封面" : "采用为本书封面") {
                                store.setCoverSVG(coverSVGCode)
                                adopted = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(adopted)
                            Button(copiedSVG ? "已复制 ✓" : "复制 SVG") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(coverSVGCode, forType: .string)
                                copiedSVG = true
                                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedSVG = false }
                            }
                            .controlSize(.mini)
                        }
                        if adopted {
                            Label("已采用——回书架即可看到新封面", systemImage: "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                    }
                    Spacer()
                }
            } else if !resultText.isEmpty {
                ScrollView {
                    Text(resultText)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                HStack {
                    Text("结果已生成（\(resultText.count) 字）。").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(copiedText ? "已复制 ✓" : "复制全文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resultText, forType: .string)
                        copiedText = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedText = false }
                    }
                    .controlSize(.mini)
                    if tool == .analyze {
                        Button(savedAsProposal ? "已存为备忘提案" : "存为备忘提案") {
                            Task {
                                await store.addProposal(AIProposal(
                                    capability: .analyze,
                                    title: "拆书报告",
                                    note: "AI 工具箱产出", payload: .memo(resultText)))
                                savedAsProposal = true
                            }
                        }
                        .controlSize(.mini)
                        .disabled(savedAsProposal)
                    }
                }
            } else if !ai.running, let newCount = ai.lastRunNewProposals, tool == .canonClassify {
                if newCount == 0 {
                    Text("完成——本次没有产出归类提案，可重试一次。").font(.caption).foregroundStyle(.secondary)
                } else {
                    classifyReview
                }
            } else if !ai.running, let newCount = ai.lastRunNewProposals,
                      tool == .organize || tool == .shortStory {
                if newCount == 0 {
                    Text("完成——本次没有产出提案，可重试一次。").font(.caption).foregroundStyle(.secondary)
                } else {
                    runProposalsReview
                }
            }
        }
        .padding(.top, ZBSpace.xs)
        .animation(ZBMotion.standard(reduceMotion: reduceMotion), value: resultText)
    }

    // MARK: 设定归类就地审阅：结果直接在本弹窗过目 + 一键采纳，不必绕道收件箱
    //（提案仍登记在收件箱留痕，采纳走同一条 acceptProposal 路径，铁律不变）

    /// 最新一条归类提案（收件箱 newest-first，可能已被作者在收件箱先行处理）
    private var latestClassifyProposal: AIProposal? {
        // 只看本次运行登记的提案：否则第二次运行失败时会把上一轮结果当成本次结果展示
        store.proposals.first {
            $0.capability == .canonClassify && ai.lastRunProposalIDs.contains($0.id)
        }
    }

    @ViewBuilder
    private var classifyReview: some View {
        if let p = latestClassifyProposal, case .canonClassify(let items) = p.payload {
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                HStack {
                    Label("归类结果（\(items.count) 篇）", systemImage: "square.grid.3x3.square")
                        .font(.caption.bold())
                    Spacer()
                    switch p.status {
                    case .pending:
                        Button("全部采纳") {
                            if store.acceptProposal(p.id) {
                                localNote = "归类已全部采纳"
                            } else {
                                localNote = nil
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    case .accepted:
                        Label("已采纳 ✓——设定页已按类别分组", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .rejected:
                        Label("已在收件箱拒收", systemImage: "xmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.title).font(.caption).frame(maxWidth: 180, alignment: .leading)
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
                                        .frame(maxWidth: 220, alignment: .trailing).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
                if let issues = store.lastAcceptIssues, p.status == .pending {
                    Text(issues).font(.caption2).foregroundStyle(.orange)
                }
                Text("采纳 = 写回分类与改名（按现有标题匹配；改名撞名自动跳过，不丢文档）。逐条微调可去「提案收件箱」。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 整理旧稿 / 短篇成稿就地审阅：本次产出直接在本弹窗过目 + 一键采纳
    //（与设定归类同思路：结果不逼用户绕道收件箱，提案仍在收件箱留痕，采纳走同一 acceptProposal 路径）

    private var runProposalsReview: some View {
        let runProposals = store.proposals.filter { ai.lastRunProposalIDs.contains($0.id) }
        let pending = runProposals.filter { $0.status == .pending }
        return VStack(alignment: .leading, spacing: ZBSpace.xs) {
            HStack {
                Label("本次产出（\(runProposals.count) 条）", systemImage: "tray.full")
                    .font(.caption.bold())
                Spacer()
                if pending.isEmpty {
                    Label("已处理 ✓", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button("全部采纳") {
                        for p in pending { store.acceptProposal(p.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(runProposals) { p in
                        HStack(spacing: 6) {
                            Text(Self.payloadTag(p.payload))
                                .font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .cornerRadius(4)
                            Text(p.title).font(.caption).lineLimit(1)
                            Spacer()
                            Text(p.status.rawValue)
                                .font(.caption2)
                                .foregroundStyle(p.status == .accepted ? Color.green :
                                                    p.status == .rejected ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
            .frame(maxHeight: 120)
            if let issues = store.lastAcceptIssues, !pending.isEmpty {
                Text(issues).font(.caption2).foregroundStyle(.orange)
            }
            Text("采纳 = 按各提案语义写回（设定同题保护、伏笔同 id 合并、草稿先存快照——重试不重复）。逐条裁决去「提案收件箱」。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private static func payloadTag(_ p: ProposalPayload) -> String {
        switch p {
        case .outlineEvents: return "时间线"
        case .storylines: return "故事线"
        case .canon: return "设定"
        case .clues: return "伏笔"
        case .skeleton: return "骨架"
        case .draft: return "草稿"
        case .memoryPack: return "记忆"
        case .report: return "审校"
        case .deslop: return "去AI味"
        case .memo: return "备忘"
        case .canonClassify: return "归类"
        case .dossier: return "档案卡"
        case .clueFixes: return "埋点修复"
        case .outlineUpdates: return "大纲同步"
        }
    }

    private func run() {
        resultText = ""
        coverSVGCode = ""
        adopted = false
        savedAsProposal = false
        // 清上轮残留：否则未运行就显示"完成"或上轮错误
        ai.lastToolLog = []
        ai.lastError = nil
        ai.lastRunNewProposals = nil
        localNote = nil
        Task {
            switch tool {
            case .analyze:
                let r = await ai.runAnalyzeText(store: store, config: vm.config, referenceText: referenceText, focus: analyzeFocus)
                resultText = r ?? ""
            case .organize:
                await ai.runOrganize(store: store, config: vm.config)
                if ai.lastError == nil {
                    localNote = "旧稿整理完成——\(ai.lastRunNewProposals ?? 0) 条提案待审"
                }
            case .canonClassify:
                await ai.runCanonClassify(store: store, config: vm.config)
                if ai.lastError == nil {
                    localNote = "设定归类完成——结果在下方，过目后一键采纳"
                }
            case .coverSVG:
                let r = await ai.runCoverSVG(store: store, config: vm.config, authorName: coverAuthor,
                                                mood: coverMood, direction: coverDirection)
                if let code = CoverSVG.extractSVG(r ?? "") {
                    coverSVGCode = code
                } else {
                    resultText = r ?? ""
                    ai.lastError = "AI 没有产出可解析的 SVG 代码块——点一次重试，或改写画面方向。"
                }
            case .shortStory:
                await ai.runShortStory(store: store, config: vm.config,
                                          chapter: chapterNumber, conflict: shortConflict, words: shortWords)
            }
        }
    }


    private var previewImage: NSImage {
        CoverSVG.render(coverSVGCode, width: 180, height: 240)
            ?? CoverSVG.render("<svg xmlns='http://www.w3.org/2000/svg' width='180' height='240'><rect width='180' height='240' fill='#333'/></svg>",
                                       width: 180, height: 240)!
    }
}
