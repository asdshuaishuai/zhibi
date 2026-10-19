import SwiftUI

// MARK: - AI 工具箱：拆书 / 整理旧稿 / 封面提案 / 短篇成稿（对标 story-long-analyze /
// story-import 的「整理三类资料」/ story-cover / story-short-write）
//
// 运行语义分两类：
// - 拆书 / 封面提案：纯文本产出（runTextOnly 通道），结果就地展示 + 一键存为备忘提案
// - 整理旧稿 / 短篇成稿：走提案通道（canon/clues/draft），结果在收件箱审

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
    @State private var showSaveFailed = false

    private var needsStore: Bool { tool == .organize || tool == .shortStory }

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

        // 结果区（纯文本类工具就地展示；提案类完成后提示去收件箱）
        .overlay(alignment: .bottom) {
            if ai.running || !resultText.isEmpty || ai.lastError != nil || !ai.lastToolLog.isEmpty {
                resultFooter
            }
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
        case .organize, .coverSVG, .shortStory: return true
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
            } else if !ai.running, ai.lastRunNewProposals != nil,
                      tool == .organize || tool == .shortStory || tool == .canonClassify {
                Text("完成——产出已进「提案收件箱」，去逐条审阅采纳。").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.top, ZBSpace.xs)
        .animation(ZBMotion.standard(reduceMotion: reduceMotion), value: resultText)
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
        Task {
            switch tool {
            case .analyze:
                let r = await ai.runAnalyzeText(store: store, referenceText: referenceText, focus: analyzeFocus)
                resultText = r ?? ""
            case .organize:
                await ai.runOrganize(store: store, config: vm.config)
                vm.showToast("旧稿整理完成——\(vm.ai.lastRunNewProposals ?? 0) 条提案待审")
            case .canonClassify:
                await ai.runCanonClassify(store: store, config: vm.config)
                vm.showToast("设定归类完成——\(vm.ai.lastRunNewProposals ?? 0) 条提案待审")
            case .coverSVG:
                let r = await ai.runCoverSVG(store: store, authorName: coverAuthor,
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
