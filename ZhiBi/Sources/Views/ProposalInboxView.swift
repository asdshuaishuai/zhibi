import SwiftUI

// MARK: - 提案收件箱：AI 的一切产出在这里被作者裁决（接受 / 修改后接受 / 拒绝）

struct ProposalInboxView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    @State private var filterPendingOnly = true
    @State private var expanded: Set<UUID> = []

    private var visible: [AIProposal] {
        filterPendingOnly ? store.proposals.filter { $0.status == .pending } : store.proposals
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "tray.full")
                Text("提案收件箱").font(.headline)
                Text("AI 永不直接改动你的书——一切产出在此裁决")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Toggle("只看待确认", isOn: $filterPendingOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button("清空已裁决") {
                    store.proposals.removeAll { $0.status != .pending }
                    store.saveSoon()
                }
                .controlSize(.small)
            }
            .padding(12)

            if visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("收件箱是空的。\n在章节页点「AI 搭骨架 / 一键验证 / 去AI味」，产出都会送到这里等你裁决。")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visible) { p in
                            proposalCard(p)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(12)
                    .animation(.snappy(duration: 0.25), value: store.proposals.map(\.id))
                }
            }
        }
    }

    private func proposalCard(_ p: AIProposal) -> some View {
        let isOpen = expanded.contains(p.id) || p.status == .pending
        return VStack(alignment: .leading, spacing: 8) {
            // 头部
            HStack {
                capabilityTag(p.capability)
                Text(p.title).font(.callout.bold())
                if let n = p.chapterNumber {
                    Text("第\(n)章").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch p.status {
                case .pending:
                    Text("待确认").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15)).foregroundStyle(.orange)
                        .cornerRadius(6)
                case .accepted:
                    Label("已采纳", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                case .rejected:
                    Label("已拒绝", systemImage: "xmark.circle").font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    if expanded.contains(p.id) { expanded.remove(p.id) } else { expanded.insert(p.id) }
                } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }

            if !p.note.isEmpty {
                Text(p.note).font(.caption).foregroundStyle(.secondary)
            }

            if isOpen {
                payloadView(p)

                if p.status == .pending {
                    HStack {
                        Spacer()
                        Button("拒绝", role: .destructive) {
                            store.rejectProposal(p.id)
                        }
                        Button("接受并入库") {
                            store.acceptProposal(p.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
            }
        }
        .padding(12)
        .zbGlass(cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(p.status == .pending ? Color.orange.opacity(0.4) : Color.secondary.opacity(0.15))
        )
    }

    private func capabilityTag(_ c: AICapability) -> some View {
        Text(c.rawValue).font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12))
            .foregroundStyle(Color.accentColor)
            .cornerRadius(6)
    }

    // MARK: - 负载渲染

    @ViewBuilder
    private func payloadView(_ p: AIProposal) -> some View {
        switch p.payload {
        case .outlineEvents(let events):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(events, id: \.id) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(e.id)] 第\(e.chapter)章").font(.caption.monospaced()).frame(width: 90, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("真相：\(e.objectiveFact)").font(.caption)
                            if e.revealed {
                                Text("读者已知：\(e.readerKnowledge)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("未揭示｜读者以为：\(e.readerKnowledge)").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Text("采纳后可在「大纲·时间线」继续编辑。").font(.caption2).foregroundStyle(.tertiary)
            }

        case .storylines(let lines):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines) { l in
                    Text("[\(l.id)] \(l.name)（\(l.kind.rawValue)\(l.isThroughLine ? "·贯穿" : "")）\(l.notes)")
                        .font(.caption)
                }
            }

        case .clues(let clues):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(clues) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("[\(c.id)] \(c.title)（\(c.scale.rawValue)｜\(c.timing.rawValue)｜埋于第\(c.plantedChapter)章）")
                            .font(.caption.bold())
                        Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        if !c.plantedQuote.isEmpty {
                            Text("种下原文：「\(c.plantedQuote)」").font(.caption2).foregroundStyle(.teal)
                        }
                    }
                    .padding(6)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(6)
                }
            }

        case .skeleton(let sk):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sk.beats.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1)").font(.caption2.bold()).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sk.beats[i].summary).font(.callout)
                            Text(sk.beats[i].purpose + (sk.beats[i].suggestedWords > 0 ? "｜约\(sk.beats[i].suggestedWords)字" : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !sk.endHook.isEmpty { Label("章尾：\(sk.endHook)", systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.orange) }
                ForEach(sk.mustDeliver, id: \.self) { Label($0, systemImage: "checkmark.diamond").font(.caption).foregroundStyle(.blue) }
                ForEach(sk.mustAvoid, id: \.self) { Label($0, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                if !sk.clueTouches.isEmpty {
                    Text("伏笔触点：" + sk.clueTouches.map { "[\($0.clueID)] \($0.action.rawValue)" }.joined(separator: "，"))
                        .font(.caption).foregroundStyle(.teal)
                }
                Text("采纳后请到章节页检查、修改骨架，再点「批准此骨架」。正文永远由你亲笔。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

        case .memoryPack(let facts, let summary, let newClues):
            VStack(alignment: .leading, spacing: 4) {
                Text("摘要：\(summary.summary)").font(.caption)
                if !summary.keyEvents.isEmpty {
                    Text("关键事件：\(summary.keyEvents.joined(separator: "；"))").font(.caption).foregroundStyle(.secondary)
                }
                Text("事实 \(facts.count) 条：").font(.caption.bold())
                ForEach(facts) { f in
                    Text("• \(f.subject) \(f.predicate) \(f.object)\(f.publicToReader ? "" : "（暗线）")")
                        .font(.caption)
                }
                if !newClues.isEmpty {
                    Text("新钩子候选 \(newClues.count) 条：").font(.caption.bold()).foregroundStyle(.orange)
                    ForEach(newClues) { c in
                        Text("• \(c.title)：\(c.detail)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

        case .report(let report):
            VStack(alignment: .leading, spacing: 4) {
                if report.deterministicIssues.isEmpty && report.aiIssues.isEmpty {
                    Text("未发现问题。").font(.callout).foregroundStyle(.green)
                }
                ForEach(report.allIssues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Text(issue.severity.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(severityColor(issue.severity).opacity(0.15))
                            .foregroundStyle(severityColor(issue.severity))
                            .cornerRadius(5)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("【\(issue.category)】\(issue.message)").font(.caption.bold())
                            if !issue.evidence.isEmpty {
                                Text("证据：\(issue.evidence)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if !issue.suggestion.isEmpty {
                                Text("建议：\(issue.suggestion)").font(.caption2).foregroundStyle(.teal)
                            }
                        }
                    }
                }
                if let lint = report.lintSummary {
                    Text("本地AI味扫描：\(lint.grade)｜禁用词密度 \(String(format: "%.1f", lint.bannedPerKilo))/千字")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

        case .deslop(let report):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("诊断：\(report.grade)").font(.caption.bold())
                    if let lint = report.lint {
                        Text("（本地扫描：禁用词 \(String(format: "%.1f", lint.bannedPerKilo))/千字）")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("全部采纳") {
                        var snapshotted = false
                        for s in report.suggestions where !s.applied {
                            _ = vm.applyDeslopSuggestion(s, chapter: report.chapter,
                                                         snapshotTag: snapshotted ? nil : "deslop前")
                            snapshotted = true
                        }
                        store.acceptProposal(p.id)
                    }
                    .controlSize(.small)
                }
                ForEach(report.suggestions) { s in
                    HStack(alignment: .top, spacing: 8) {
                        Text(s.gate.isEmpty ? "·" : s.gate)
                            .font(.caption2.bold()).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("原：\(s.original)").font(.caption).foregroundStyle(.red.opacity(0.8))
                            Text("改：\(s.replacement)").font(.caption).foregroundStyle(.green.opacity(0.9))
                            if !s.reason.isEmpty {
                                Text(s.reason).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("采纳") {
                            if vm.applyDeslopSuggestion(s, chapter: report.chapter,
                                                        snapshotTag: s.applied ? nil : "deslop前") {
                                markSuggestionApplied(p, s)
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(5)
                    .zbGlass(cornerRadius: 6)
                }
                Text("改最少、只改怎么说：每一处都由你决定。首次采纳前自动存正文快照（章节目录 snapshots/，可回滚）。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

        case .draft(let draft):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ZBChip(text: "v\(draft.version)", color: .accentColor, filled: true)
                    Text("\(WordStats.chineseCount(draft.text)) 字").font(.caption2).foregroundStyle(.tertiary)
                    if !draft.feedbackHistory.isEmpty {
                        Text("已按 \(draft.feedbackHistory.count) 轮意见修订").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                MarkdownPreview(markdown: draft.text)
                    .frame(height: 260)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .cornerRadius(8)
                Text("接受 = 写入本章正文（覆盖前自动存快照，可回滚）。也可在流水线里继续给意见修复。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

        case .memo(let text):
            MarkdownPreview(markdown: text, fontSize: 13)
                .frame(minHeight: 100)
        }
    }

    private func markSuggestionApplied(_ p: AIProposal, _ s: DeslopSuggestion) {
        guard let idx = store.proposals.firstIndex(where: { $0.id == p.id }) else { return }
        if case .deslop(var report) = store.proposals[idx].payload {
            if let sIdx = report.suggestions.firstIndex(where: { $0.id == s.id }) {
                report.suggestions[sIdx].applied = true
                store.proposals[idx].payload = .deslop(report)
                store.saveSoon()
            }
        }
    }

    private func severityColor(_ s: Severity) -> Color {
        switch s {
        case .blocker: return .red
        case .warning: return .orange
        case .note: return .secondary
        }
    }
}
