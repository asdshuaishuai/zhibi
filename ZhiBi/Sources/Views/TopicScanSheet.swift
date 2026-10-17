import SwiftUI

// MARK: - 选题助手（对标 story-long-scan：开书前先看读者在看什么）
//
// 书架级工具：不依赖任何项目——AI 产出就地展示，作者自己决定开什么书。
// 结果可复制；选中方向后点「带方向去新建」，把一句话核心填进新建表单。

struct TopicScanSheet: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var material = ""
    @State private var ownAssets = ""
    @State private var resultText = ""
    @State private var copied = false

    private var inputReady: Bool {
        material.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZBSpace.sm) {
            HStack {
                Text("选题助手").font(.headline)
                Text("story-long-scan · 先找方向，再看自己能不能写")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if ai.running { ProgressView().controlSize(.small) }
            }

            Text("把平台/榜单上你看到的题材、人设、开篇钩子贴进来（越具体越好；\"FQ 榜单悬疑\"这类概述也行）。AI 提炼共性后给 2-3 个开书方向与依据。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("榜单/题材素材（\(material.count) 字，至少 20）")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $material)
                .font(.callout)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))

            TextField("你手里的资产（可选，如：想写都市、手上有三个角色设定）", text: $ownAssets)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(copied ? "已复制 ✓" : "复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resultText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .disabled(resultText.isEmpty)
                Button(ai.running ? "调研中…" : "开始调研") {
                    resultText = ""
                    Task {
                        if let r = await ai.runTopicScanResearch(config: vm.config,
                                                                    material: material,
                                                                    ownAssets: ownAssets) {
                            withAnimation(ZBMotion.standard(reduceMotion: reduceMotion)) {
                                resultText = r
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(ai.running || !inputReady)
            }

            if ai.running {
                ScrollView {
                    Text(ai.streamPreview.isEmpty ? "…" : ai.streamPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else if !resultText.isEmpty {
                ScrollView {
                    Text(resultText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ZBSpace.sm)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .cornerRadius(8)
            } else if let err = ai.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("三项产出：题材方向 ｜ 人设与开篇 ｜ 开书建议（含需要先验证的地方）。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(ZBSpace.lg)
        .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 520)
        .onDisappear { ai.lastError = nil }
    }
}
