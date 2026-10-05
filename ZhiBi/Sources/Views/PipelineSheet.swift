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
    @State private var volFrom = 1
    @State private var volTo = 20
    @State private var volDirective = ""
    @State private var wordsPerChunk = 1200

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
                    autoPipelineCard

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
                        // 宿主闸门：批准前先用确定性代码给骨架打分，问题直接摆出来
                        if let sk = store.chapter(chapterNumber)?.skeleton, !sk.beats.isEmpty {
                            let gate = SkeletonGate.evaluate(sk, store: store, chapter: chapterNumber)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("骨架闸门 \(gate.score)/100").font(.caption.bold())
                                    ZBChip(text: gate.blockers.isEmpty ? "无阻塞项" : "\(gate.blockers.count) 项阻塞",
                                           color: gate.blockers.isEmpty ? .green : .red, filled: !gate.blockers.isEmpty)
                                    if !gate.hookKind.isEmpty {
                                        ZBChip(text: "钩子·\(gate.hookKind)", color: gate.hookConcrete ? .green : .orange)
                                    }
                                    ZBChip(text: "埋\(gate.plantCount)/推\(gate.developCount)/收\(gate.revealCount)", color: .blue)
                                    Spacer()
                                }
                                ForEach(gate.issues.prefix(5)) { i in
                                    Text("[\(i.severity.rawValue)] \(i.message) → \(i.suggestion)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .underPageBackgroundColor))
                            .cornerRadius(6)
                        }
                        // 卷骨架：逐章搭骨架只见树木不见森林，卷级弧光要在这一层设计
                        DisclosureGroup("规划整卷弧光（多章路标，不逐章写节拍）") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Stepper("从第 \(volFrom) 章", value: $volFrom, in: 1...9999)
                                    Stepper("到第 \(volTo) 章", value: $volTo, in: 1...9999)
                                }
                                .controlSize(.small)
                                TextEditor(text: $volDirective)
                                    .font(.callout).frame(minHeight: 44)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                                Button("出卷级设计提案") {
                                    Task { await vm.ai.runVolumeSkeleton(store: store, config: vm.config,
                                                                         from: volFrom, to: volTo,
                                                                         directive: volDirective.isEmpty ? mainline : volDirective) }
                                }
                                .zbGlassButton()
                                .disabled(vm.ai.running || volTo < volFrom)
                                Text("按起承转合设计这一段的赌注递增、章级路标、伏笔收支与期待感账；作者认可后再逐章搭骨架。一次最多 40 章。")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
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
                            Button {
                                Task { await vm.ai.runDraftByScenes(store: store, config: vm.config,
                                                                    chapter: chapterNumber, mainline: mainline,
                                                                    wordsPerChunk: wordsPerChunk) }
                            } label: {
                                Label("分段写 v\(store.nextDraftVersion(for: chapterNumber))", systemImage: "square.stack.3d.up")
                            }
                            .zbGlassButton()
                            .disabled(vm.ai.running || store.chapter(chapterNumber)?.skeleton?.humanApproved != true)
                            .help("按骨架节拍分块续写再拼装。3000 字以上一次性生成，后半段必然退化（复读、赶结尾、把后几拍压成一两句交代）；分块更稳。需要先有批准的骨架。")
                        }
                        HStack(spacing: 8) {
                            Stepper("每段约 \(wordsPerChunk) 字", value: $wordsPerChunk, in: 600...2400, step: 200)
                                .controlSize(.mini)
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
        .onAppear {
            // 默认把当前章所在的那一卷（每 20 章一卷，与分卷导出口径一致）填进去
            let volStart = max(1, ((chapterNumber - 1) / 20) * 20 + 1)
            volFrom = volStart
            volTo = volStart + 19
        }
    }

    /// 一键成章：草稿 → 一致性审查 → 去AI味 自动串起来，停在「采纳」之前。
    /// 骨架不在自动串的范围里——它是写前契约，属于正典决定，必须作者亲自批准。
    private var autoPipelineCard: some View {
        let approved = store.chapter(chapterNumber)?.skeleton?.humanApproved == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").foregroundStyle(Color.accentColor)
                Text("一键成章").font(.headline)
                Spacer()
                Button {
                    Task { await vm.ai.runAutoPipeline(store: store, config: vm.config,
                                                       chapter: chapterNumber, mainline: mainline) }
                } label: {
                    Label(vm.ai.running ? (vm.ai.pipelineStage.isEmpty ? "跑着…" : vm.ai.pipelineStage) : "一键跑到底",
                          systemImage: "play.fill")
                }
                .zbGlassButton(prominent: true)
                .disabled(vm.ai.running)
            }
            Text(approved
                 ? "骨架已批准 → 会依次跑：写草稿 · 一致性审查 · 去AI味，产出全进收件箱，**停在采纳之前**。"
                 : "还没有批准的骨架 → 这一步只会先出骨架提案并停下。骨架是写前契约，得你亲自批准（一键流程不代批）。")
                .font(.caption).foregroundStyle(approved ? Color.secondary : Color.orange)
            if !vm.ai.pipelineDone.isEmpty {
                HStack(spacing: 6) {
                    ForEach(vm.ai.pipelineDone, id: \.self) { s in
                        ZBChip(text: "✓ \(s)", color: s.contains("失败") ? .red : .green)
                    }
                }
            }
            if !vm.ai.pipelineNote.isEmpty {
                Text(vm.ai.pipelineNote).font(.caption).foregroundStyle(.secondary)
            }
            if let err = vm.ai.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .zbCard()
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
