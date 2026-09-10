import SwiftUI

// MARK: - 一键成章流水线
// 主线(人) → 骨架+伏笔(AI) → 一键写作(AI) → 人类审查(意见) → AI 修复 → 记忆审查 → 文风综合审查 → 采纳入库
// 草稿永远以提案形态存在：人点采纳才写正文（覆盖前自动快照）。

struct PipelineSheet: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let chapterNumber: Int
    @Environment(\.dismiss) private var dismiss

    @State private var mainline = ""
    @State private var feedback = ""
    @State private var acceptedNote: String?

    private var latestDraft: AIProposal? { store.latestDraftProposal(for: chapterNumber) }
    private var draft: ChapterDraft? { latestDraft.flatMap { store.draftPayload(of: $0) } }

    var body: some View {
        let currentDraft = draft
        let currentProposal = latestDraft
        let draftWords = currentDraft.map { WordStats.chineseCount($0.text) }
        return VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stage(1, "主线（你给）") {
                        TextEditor(text: $mainline)
                            .font(.callout)
                            .frame(minHeight: 64)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                        Text("一句话到一段话都行：这章要发生什么、要什么效果。会与骨架、大纲一起交给 AI。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    stage(2, "AI 搭骨架 + 伏笔触点") {
                        HStack {
                            Button("生成骨架提案") {
                                Task { await vm.ai.runSkeleton(store: store, config: vm.config, chapter: chapterNumber, directive: mainline) }
                            }
                            .zbGlassButton()
                            .disabled(vm.ai.running)
                            if let sk = store.chapter(chapterNumber)?.skeleton, sk.humanApproved {
                                ZBChip(text: "骨架已批准", color: .green)
                            } else {
                                Text("骨架提案在收件箱，建议先批准再写作").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }

                    stage(3, "AI 一键写作") {
                        HStack {
                            Button {
                                Task { await vm.ai.runDraft(store: store, config: vm.config, chapter: chapterNumber, mainline: mainline) }
                            } label: {
                                Label(currentDraft == nil ? "写草稿 v1" : "另写一版 v\(store.nextDraftVersion(for: chapterNumber))",
                                      systemImage: "square.and.pencil")
                            }
                            .zbGlassButton(prominent: true)
                            .disabled(vm.ai.running)
                            Text("按主线 + 骨架 + 记忆召回，产出草稿提案（不直接改正文）")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    stage(4, "人类审查（读草稿，给意见）") {
                        if let draft = currentDraft {
                            HStack(spacing: 8) {
                                ZBChip(text: "v\(draft.version)", filled: true)
                                Text("\(draftWords ?? 0) 字").font(.caption2).foregroundStyle(.tertiary)
                                Spacer()
                            }
                            MarkdownPreview(markdown: draft.text)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(Color(nsColor: .underPageBackgroundColor))
                                .cornerRadius(8)
                        } else {
                            emptyHint("还没有草稿——先点上面的「写草稿」。")
                        }
                    }

                    stage(5, "AI 修复（按你的意见）") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $feedback)
                                .font(.callout)
                                .frame(minHeight: 56)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                            HStack {
                                Button("按意见修复，出 v\(store.nextDraftVersion(for: chapterNumber))") {
                                    Task {
                                        await vm.ai.runRevision(store: store, config: vm.config, chapter: chapterNumber, feedback: feedback)
                                        feedback = ""
                                    }
                                }
                                .zbGlassButton(prominent: true)
                                .disabled(vm.ai.running || feedback.trimmingCharacters(in: .whitespaces).isEmpty || currentDraft == nil)
                                Text("意见逐条落实；没提到的地方保持原样").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }

                    stage(6, "AI 记忆化审查（伏笔/设定/吃书）") {
                        HStack {
                            Button("一致性审查（审草稿）") {
                                Task { await vm.ai.runValidation(store: store, config: vm.config, chapter: chapterNumber, overrideText: currentDraft?.text) }
                            }
                            .zbGlassButton()
                            .disabled(vm.ai.running || currentDraft == nil)
                            Text("连续性矛盾/设定违背/伏笔合同/物理不可能——报告进收件箱").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    stage(7, "AI 文风综合审查（去AI味 + 强化风格）") {
                        HStack {
                            Button("三 pass 综合（审草稿）") {
                                Task { await vm.ai.runDeslop(store: store, config: vm.config, chapter: chapterNumber, overrideText: currentDraft?.text) }
                            }
                            .zbGlassButton()
                            .disabled(vm.ai.running || currentDraft == nil)
                            Text("叙事架构→篇章→措辞 + 模型指纹 + 本地扫描").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    // 采纳入库
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "square.and.arrow.down.on.square")
                            Text("满意了？采纳入库").font(.headline)
                            Spacer()
                            if let draft = currentDraft {
                                Text("草稿 \(draftWords ?? 0) 字").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("采纳 v\(currentDraft?.version ?? 0) → 写入正文") {
                                acceptDraft()
                            }
                            .zbGlassButton(prominent: true)
                            .disabled(currentDraft == nil)
                            if let note = acceptedNote {
                                Text("✓ \(note)").font(.caption).foregroundStyle(.green)
                            }
                        }
                        Text("覆盖正文前会自动存快照（章节目录 snapshots/），随时可回滚。入库后建议在章节页跑「让 AI 记一笔」更新账本。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .zbCard()
                }
                .padding(14)
            }
        }
        .frame(width: 760, height: 720)
    }

    private func acceptDraft() {
        guard let proposal = latestDraft, let draft = store.draftPayload(of: proposal) else { return }
        store.acceptProposal(proposal.id)
        acceptedNote = "草稿 v\(draft.version) 已写入第\(chapterNumber)章正文（\(WordStats.chineseCount(draft.text)) 字）"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "flowchart.fill").foregroundStyle(Color.accentColor)
            Text("一键成章流水线").font(.headline)
            Text("第\(chapterNumber)章 · 每一步都停在等你，草稿不采纳不落盘")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if vm.ai.running {
                ProgressView().controlSize(.small)
                Text(vm.ai.runningCapability?.rawValue ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Button("完成") { dismiss() }.controlSize(.small)
        }
        .padding(12)
    }

    private func stage<B: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("\(number)")
                    .font(.caption2.bold().monospacedDigit())
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.callout.bold())
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zbCard()
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
