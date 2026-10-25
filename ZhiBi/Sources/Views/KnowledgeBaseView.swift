import SwiftUI

// MARK: - 资料库：跨正文/设定/档案卡/伏笔/事实/时间线的统一检索入口
//
// 索引是派生缓存，内容变了自动重建；作者也可以手动重建验证。
// 检索默认「关键词 BM25 + 向量重排」：没有配置嵌入模型时用本地哈希向量，
// 配置了 OpenAI 兼容的 embeddingModel 则用远程向量重排（失败自动回退）。

struct KnowledgeBaseView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    /// 命中可直接跳到对应章节 / 台账；章节跳转会带上能在正文里定位的针。
    var onOpenChapter: ((Int, String?) -> Void)? = nil
    var onOpenSection: ((WorkspaceSection) -> Void)? = nil

    @ObservedObject private var indexProgress = KnowledgeIndexProgress.shared
    @State private var query = ""
    @State private var results: [KnowledgeHit] = []
    @State private var stats: KnowledgeStats?
    @State private var searching = false
    @State private var loadingStats = false
    @State private var error: String?
    @State private var kindFilter: KnowledgeKind?
    @FocusState private var searchFocused: Bool

    private var visibleResults: [KnowledgeHit] {
        guard let kindFilter else { return results }
        return results.filter { $0.chunk.kind == kindFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statsBar
            Divider()
            searchBar
            Divider()
            content
        }
        .background(ZB.canvas)
        .onAppear {
            Task { await refreshStats() }
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical.circle")
                .foregroundStyle(Color.accentColor)
            Text("资料库").font(.headline)
            Text("正文 / 设定 / 档案卡 / 伏笔 / 记忆 / 时间线 → 统一索引")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button {
                KnowledgeIndexCache.invalidate()
                Task {
                    await refreshStats()
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await performSearch(query)
                    }
                }
            } label: {
                Label("重建索引", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(loadingStats || searching)
            .help("清空派生索引，按当前书稿在后台重建")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statsBar: some View {
        HStack(alignment: .top, spacing: 18) {
            stat("片段", stats.map { "\($0.chunks)" } ?? "—")
            stat("来源类型", stats.map { "\($0.byKind.count)" } ?? "—")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(indexProgress.isBuilding
                         ? "正在建立索引 \(Int(min(1, indexProgress.fraction) * 100))%"
                         : (stats?.embeddingLabel ?? "正在后台建立索引…"))
                        .font(.caption.bold())
                        .foregroundStyle(indexProgress.isBuilding ? Color.accentColor : embeddingColor)
                    if loadingStats && !indexProgress.isBuilding {
                        ProgressView().controlSize(.mini)
                    }
                }
                if indexProgress.isBuilding {
                    ProgressView(value: min(1, indexProgress.fraction))
                        .progressViewStyle(.linear)
                        .frame(width: 150)
                } else {
                    Text("检索：关键词 BM25 + 向量余弦重排")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let stats {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        if kindFilter != nil {
                            Button {
                                kindFilter = nil
                            } label: {
                                ZBChip(text: "全部", color: .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("清除来源筛选")
                        }
                        ForEach(KnowledgeKind.allCases, id: \.self) { kind in
                            if let n = stats.byKind[kind], n > 0 {
                                Button {
                                    kindFilter = kindFilter == kind ? nil : kind
                                } label: {
                                    ZBChip(text: "\(kind.rawValue) \(n)", color: kindColor(kind),
                                           filled: kindFilter == kind)
                                }
                                .buttonStyle(.plain)
                                .help("只看\(kind.rawValue)")
                            }
                        }
                    }
                }
                .frame(maxWidth: 340)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("查人名、物件、地名、伏笔、设定或任意原文片段", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { search() }
            Button {
                search()
            } label: {
                Label("检索", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
            if searching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).font(.callout).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleResults.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ZBSpace.sm) {
                    HStack {
                        Text("找到 \(visibleResults.count) 条")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        if let kindFilter {
                            Text("· 仅看\(kindFilter.rawValue)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text("按相关度排序；引用时请核对原文")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    ForEach(visibleResults) { hit in
                        resultCard(hit)
                    }
                }
                .padding(14)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "把整本书变成可检索的记忆"
                 : (kindFilter.map { "「\($0.rawValue)」里没有「\(query)」" } ?? "没有找到「\(query)」"))
                .font(.headline)
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "资料库会把每一章正文、章摘要、每篇设定、章档案卡、伏笔、事实账本和时间线切片建索引。\n写的时候问 AI「第 12 章的断刀后来出现过吗」，它就能带着来源回答。"
                 : (kindFilter == nil
                    ? "换一个更具体的人名、物件名、地名或伏笔名试试；也可以先到「设定」或「伏笔台账」确认它是否已经写进书里。"
                    : "当前来源没有命中。点上方「全部」清除筛选，或换一个更具体的关键词。"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private enum JumpTarget {
        case chapter(Int)
        case section(WorkspaceSection)
    }

    /// 正文/摘要/骨架/档案卡回到章节；其余账本回到对应工作区。
    private func jumpTarget(for chunk: KnowledgeChunk) -> JumpTarget? {
        switch chunk.kind {
        case .prose, .summary, .skeleton, .dossier:
            guard let n = chunk.chapter, onOpenChapter != nil else { return nil }
            return .chapter(n)
        case .canon:
            return onOpenSection == nil ? nil : .section(.canon)
        case .clue:
            return onOpenSection == nil ? nil : .section(.clues)
        case .fact:
            return onOpenSection == nil ? nil : .section(.memory)
        case .event, .storyline, .stage:
            return onOpenSection == nil ? nil : .section(.outline)
        }
    }

    private func jump(_ target: JumpTarget, needle: String? = nil) {
        switch target {
        case .chapter(let n):
            onOpenChapter?(n, needle)
        case .section(let section):
            onOpenSection?(section)
        }
    }

    private func resultCard(_ hit: KnowledgeHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZBChip(text: hit.chunk.kind.rawValue, color: kindColor(hit.chunk.kind))
                Text(hit.chunk.citation)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.2f", hit.score))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Button {
                    vm.chatInvocation = ChatInvocation(
                        prompt: KnowledgeQuickPrompt.handOff(hit),
                        chapter: hit.chunk.chapter)
                } label: {
                    Label("交给 AI", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("把这段资料带进右侧 AI 对话，接着提问或续写")
                if let target = jumpTarget(for: hit.chunk) {
                    Button {
                        jump(target, needle: KnowledgeFocus.needle(for: hit))
                    } label: {
                        Label("前往", systemImage: "arrow.up.forward.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("跳到这条资料的出处，核对原文")
                }
            }
            Text(hit.chunk.text)
                .font(.callout)
                .lineLimit(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !hit.matchedTerms.isEmpty {
                Text("命中：" + hit.matchedTerms.prefix(8).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zbCard(padding: 10)
    }

    private func kindColor(_ kind: KnowledgeKind) -> Color {
        switch kind {
        case .canon: return .blue
        case .prose: return .accentColor
        case .summary: return .cyan
        case .skeleton: return .mint
        case .dossier: return .purple
        case .clue: return .orange
        case .fact: return .green
        case .event: return .teal
        case .storyline: return .indigo
        case .stage: return .brown
        }
    }

    private var embeddingColor: Color {
        guard let stats, let model = stats.embeddingModel, !model.isEmpty else { return .secondary }
        return stats.embeddingRun == .fallback ? .orange : Color.accentColor
    }

    private func refreshStats(run: KnowledgeEmbeddingRun? = nil) async {
        loadingStats = true
        stats = await KnowledgeEngine.stats(store: store, config: vm.config, run: run)
        loadingStats = false
    }

    private func search() {
        Task { await performSearch(query) }
    }

    private func performSearch(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        searching = true
        error = nil
        let outcome = await KnowledgeEngine.searchDetailed(
            store: store, query: q, limit: 24, config: vm.config)
        results = outcome.hits
        stats = await KnowledgeEngine.stats(store: store, config: vm.config, run: outcome.run)
        searching = false
    }
}
