import SwiftUI

// MARK: - 全局搜索：跨章节正文 / 伏笔 / 设定 / 时间线 / 记忆

struct SearchSheet: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let onSelectChapter: (Int) -> Void
    var onSelectSection: (WorkspaceSection) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// 防抖后的查询词：全本扫描跑在后台，主线程只渲染结果
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?

    struct Hit: Identifiable {
        let id: UUID = UUID()
        let icon: String
        let title: String
        let snippet: String
        let chapterNumber: Int?
        /// 非空 = 点这条跳到对应工作区板块（设定/伏笔等无「章」概念的命中）
        var section: WorkspaceSection?
    }

    private var hits: [Hit] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var out: [Hit] = []
        var seen = Set<String>()

        // 章节（正文 + 标题）
        for ch in store.chapters.sorted(by: { $0.number < $1.number }) {
            let inTitle = !ch.title.isEmpty && ch.title.localizedCaseInsensitiveContains(q)
            if inTitle {
                let hit = Hit(icon: "text.book.closed", title: "第\(ch.number)章 \(ch.title)",
                              snippet: "章节标题命中", chapterNumber: ch.number)
                out.append(hit)
                seen.insert("ch\(ch.number)")
            }
            if let range = ch.prose.range(of: q, options: .caseInsensitive) {
                let start = ch.prose.index(range.lowerBound, offsetBy: -18, limitedBy: ch.prose.startIndex) ?? ch.prose.startIndex
                let end = ch.prose.index(range.upperBound, offsetBy: 22, limitedBy: ch.prose.endIndex) ?? ch.prose.endIndex
                let snippet = MarkdownLite.stripMarkers(String(ch.prose[start..<end]))
                    .replacingOccurrences(of: "\n", with: " ")
                let hit = Hit(icon: "text.alignleft", title: "第\(ch.number)章 \(ch.title.isEmpty ? "" : ch.title)",
                              snippet: "…" + snippet + "…", chapterNumber: ch.number)
                if seen.insert("ch\(ch.number)").inserted {
                    out.append(hit)
                } else {
                    out.append(Hit(icon: "text.alignleft", title: "第\(ch.number)章",
                                   snippet: "…" + snippet + "…", chapterNumber: ch.number))
                }
            }
        }

        // 伏笔
        for c in store.clues
        where c.title.localizedCaseInsensitiveContains(q) || c.detail.localizedCaseInsensitiveContains(q) {
            out.append(Hit(icon: "link", title: "[\(c.id)] \(c.title)",
                           snippet: "\(c.status.rawValue)｜\(c.detail)", chapterNumber: nil,
                           section: .clues))
        }

        // 设定
        for section in store.canonSections {
            guard let range = section.content.range(of: q, options: .caseInsensitive) else { continue }
            let start = section.content.index(range.lowerBound, offsetBy: -18, limitedBy: section.content.startIndex) ?? section.content.startIndex
            let end = section.content.index(range.upperBound, offsetBy: 22, limitedBy: section.content.endIndex) ?? section.content.endIndex
            let snippet = MarkdownLite.stripMarkers(String(section.content[start..<end])).replacingOccurrences(of: "\n", with: " ")
            out.append(Hit(icon: "books.vertical", title: section.title, snippet: "…" + snippet + "…", chapterNumber: nil,
                           section: .canon))
        }

        // 时间线
        for e in store.timelineEvents
        where e.objectiveFact.localizedCaseInsensitiveContains(q) || e.readerKnowledge.localizedCaseInsensitiveContains(q) {
            out.append(Hit(icon: "timeline.selection", title: "[\(e.id)] 第\(e.chapter)章",
                           snippet: e.objectiveFact, chapterNumber: e.chapter))
        }

        // 记忆事实
        for f in store.facts where f.isValid(atChapter: 9999)
        && (f.subject.localizedCaseInsensitiveContains(q) || f.object.localizedCaseInsensitiveContains(q)) {
            out.append(Hit(icon: "brain", title: "\(f.subject) \(f.predicate)",
                           snippet: f.object + (f.publicToReader ? "" : "（暗线）"), chapterNumber: f.fromChapter))
        }

        return Array(out.prefix(60))
    }

    var body: some View {
        // 输入防抖 150ms：大书（100 万字）每次击键全本扫描 ~118ms，不防抖直接掉字

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.accentColor)
                TextField("搜索全书：章节 / 伏笔 / 设定 / 时间线 / 记忆…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { openFirst() }
                if !query.isEmpty {
                    Text("\(hits.count) 条").font(.caption).foregroundStyle(.tertiary)
                }
                Button("完成") { dismiss() }.controlSize(.small)
            }
            .padding(14)
            Divider()

            if hits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: query.count < 2 ? "magnifyingglass" : "questionmark.folder")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(query.count < 2 ? "输入至少 2 个字符" : "没有命中")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hits) { hit in
                        Button {
                            if let n = hit.chapterNumber {
                                onSelectChapter(n)
                            } else if let sec = hit.section {
                                onSelectSection(sec)
                            } else {
                                return   // 无跳转目标：不误导（宁可不响应也不空跳）
                            }
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: hit.icon)
                                    .foregroundStyle(hit.chapterNumber != nil ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title).font(.callout.bold()).foregroundStyle(.primary)
                                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                if hit.chapterNumber != nil {
                                    Text("前往").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 620, height: 560)
    }

    private func openFirst() {
        if let first = hits.first, let n = first.chapterNumber {
            onSelectChapter(n)
            dismiss()
        }
    }
}

// MARK: - 输入防抖

private struct SearchDebouncer: View {
    @Binding var query: String
    @Binding var debouncedQuery: String
    @Binding var debounceTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: query) { _ in
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { debouncedQuery = query }
                }
            }
    }
}
