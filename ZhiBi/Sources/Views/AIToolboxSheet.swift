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
    let chapterNumber: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tool: String, CaseIterable, Identifiable {
        var id: String { rawValue }

        case analyze = "拆书"
        case organize = "整理旧稿"
        case coverBrief = "封面提案"
        case shortStory = "短篇成稿"

        var icon: String {
            switch self {
            case .analyze: return "text.magnifyingglass"
            case .organize: return "tray.and.arrow.down"
            case .coverBrief: return "photo.artframe"
            case .shortStory: return "doc.richtext"
            }
        }

        var intro: String {
            switch self {
            case .analyze: return "贴一段参考文本（建议前 3 章），AI 从钩子/冲突/悬念/节奏四维拆解，每个判断给出原文位置。学结构，不抄情节。"
            case .organize: return "正文有了、账本还没建？AI 把散在各章的信息整理成三类资料：设定与人物 / 剧情时间线 / 伏笔追踪——作者核对后再续写。"
            case .coverBrief: return "产出一份可直接交给画师或图像模型的封面设计说明：构图/配色/文字排版/氛围关键词/避雷，附保守与差异化两版。"
            case .shortStory: return "围绕一个核心冲突写短篇：起冲突/推转折/落结局。产出大纲+全文一份草稿提案，走既有审查采纳流程。"
            }
        }
    }

    @State private var tool: Tool = .analyze
    // 拆书
    @State private var referenceText = ""
    @State private var analyzeFocus = ""
    // 封面
    @State private var coverMood = ""
    @State private var coverDirection = ""
    // 短篇
    @State private var shortConflict = ""
    @State private var shortWords = 6000
    // 运行结果（纯文本类）
    @State private var resultText = ""
    @State private var savedAsProposal = false
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
                if vm.ai.running {
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
                    .disabled(vm.ai.running || !inputReady)
            }
        }
        .padding(ZBSpace.lg)
        .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 560)

        // 结果区（纯文本类工具就地展示；提案类完成后提示去收件箱）
        .overlay(alignment: .bottom) {
            if vm.ai.running || !resultText.isEmpty || vm.ai.lastError != nil || !vm.ai.lastToolLog.isEmpty {
                resultFooter
            }
        }
    }

    private var runLabel: String {
        switch tool {
        case .analyze: return "拆解"
        case .organize: return "整理成三类资料"
        case .coverBrief: return "出封面提案"
        case .shortStory: return "写短篇草稿"
        }
    }

    private var inputReady: Bool {
        switch tool {
        case .analyze: return referenceText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50
        case .organize: return store.chapters.contains { !$0.prose.isEmpty }
        case .coverBrief: return true
        case .shortStory: return shortConflict.trimmingCharacters(in: .whitespaces).count >= 4
        }
    }

    @ViewBuilder
    private var inputSection: some View {
        switch tool {
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
        case .coverBrief:
            VStack(alignment: .leading, spacing: ZBSpace.xs) {
                Text("书名《\(store.project.title)》｜题材：\(store.project.genre.isEmpty ? "（未定）" : store.project.genre)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("氛围要求（如：压迫感、冷色调、史诗）", text: $coverMood)
                    .textFieldStyle(.roundedBorder)
                TextField("画面方向（如：少年背影 + 断刀 + 雨夜；避免：剧透画面）", text: $coverDirection)
                    .textFieldStyle(.roundedBorder)
                Text("产出是设计说明文本——交给画师或图像模型用；本应用不做图像生成。")
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
            if let err = vm.ai.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if vm.ai.running {
                ForEach(vm.ai.lastToolLog.suffix(2), id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !resultText.isEmpty {
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
                    Button("复制全文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resultText, forType: .string)
                    }
                    .controlSize(.mini)
                    if tool == .analyze || tool == .coverBrief {
                        Button(savedAsProposal ? "已存为备忘提案" : "存为备忘提案") {
                            Task {
                                await store.addProposal(AIProposal(
                                    capability: tool == .analyze ? .analyze : .coverBrief,
                                    title: tool == .analyze ? "拆书报告" : "封面设计提案",
                                    note: "AI 工具箱产出", payload: .memo(resultText)))
                                savedAsProposal = true
                            }
                        }
                        .controlSize(.mini)
                        .disabled(savedAsProposal)
                    }
                }
            } else if !vm.ai.running, tool == .organize || tool == .shortStory {
                Text("完成——产出已进「提案收件箱」，去逐条审阅采纳。").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.top, ZBSpace.xs)
        .animation(ZBMotion.standard(reduceMotion: reduceMotion), value: resultText)
    }

    private func run() {
        resultText = ""
        savedAsProposal = false
        Task {
            switch tool {
            case .analyze:
                let r = await vm.ai.runAnalyzeText(store: store, referenceText: referenceText, focus: analyzeFocus)
                resultText = r ?? ""
            case .organize:
                await vm.ai.runOrganize(store: store, config: vm.config)
            case .coverBrief:
                let r = await vm.ai.runCoverBriefText(store: store, mood: coverMood, direction: coverDirection)
                resultText = r ?? ""
            case .shortStory:
                await vm.ai.runShortStory(store: store, config: vm.config,
                                          chapter: chapterNumber, conflict: shortConflict, words: shortWords)
            }
        }
    }
}
