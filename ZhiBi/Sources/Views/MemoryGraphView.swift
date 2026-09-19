import SwiftUI

// MARK: - 记忆图谱：人物关系 / 剧情 / 事件 三种交叉视图
//
// 与账本同源：图由 MemoryGraphEngine 从事实/故事线/事件/伏笔机械派生。
// 交互：拖拽平移、滚轮缩放（触控板双指）、点节点出「记忆回溯」全链、
// 顶部搜索框做全库关键词回溯。跳「去第 N 章」回调工作区打开该章。

struct MemoryGraphView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    let onGotoChapter: (Int) -> Void

    enum GraphMode: String, CaseIterable {
        case characters = "人物关系图"
        case plot = "剧情图"
        case events = "事件图"
    }

    @State private var mode: GraphMode = .characters
    @State private var selectedID: String?
    @State private var query = ""
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var scale: CGFloat = 1.0

    /// 图缓存：只在账本规模签名变化时重建（避免拖拽每帧全量重建 4-6 次）。
    /// 用类引用持有，避免在 body 求值里写 @State。
    private final class GraphCache {
        var stamp = Int.min
        var graph = MemoryGraph()
    }
    @State private var graphCache = GraphCache()

    private var graph: MemoryGraph {
        let stamp = store.facts.count + store.timelineEvents.count * 1_000
            + store.clues.count * 1_000_000 + store.storylines.count * 1_000_000_000
            + store.characterAliases.count * 1_000_000_000_000
        if graphCache.stamp != stamp {
            graphCache.stamp = stamp
            graphCache.graph = MemoryGraphEngine.build(from: store)
        }
        return graphCache.graph
    }

    private var nodeColor: [MemoryNodeKind: Color] {
        [
            .character: .teal,
            .storyline: .indigo,
            .event: Color.accentColor,
            .clue: Color(nsColor: NSColor(red: 0.784, green: 0.298, blue: 0.204, alpha: 1)),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            graphPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
            recallPanel
                .frame(width: 300)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .navigationTitle("记忆图谱")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $mode) {
                    ForEach(GraphMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pan = .zero; scale = 1.0
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("复位视图")
            }
        }
    }

    // MARK: - 图谱画布

    private var graphPane: some View {
        GeometryReader { geo in
            let size = geo.size
            let positions = layoutPositions(mode: mode, graph: graph, in: size)

            ZStack {
                Canvas { context, _ in
                    drawEdges(context: context, mode: mode, graph: graph, positions: positions)
                    drawNodes(context: context, mode: mode, graph: graph, positions: positions)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            pan = CGSize(width: panStart.width + g.translation.width,
                                         height: panStart.height + g.translation.height)
                        }
                        .onEnded { _ in panStart = pan }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale = max(0.4, min(3.0, $0)) }
                )
                .onTapGesture { loc in
                    let hit = nearestNode(loc, positions: positions, threshold: 22)
                    selectedID = hit
                }

                if positions.isEmpty {
                    emptyHint
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(emptyMessage)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .characters: return "还没有人物关系——写完几章后「提取记忆」会在人物间织出关系边；也可以直接在人物卡里登记关系事实。"
        case .plot: return "还没有故事线——去「大纲·时间线」让 AI 搭框架，或手动登记主线与事件。"
        case .events: return "还没有时间线事件——去「大纲·时间线」让 AI 搭框架，事件会按章节铺开，伏笔的「埋→揭」自动成弧。"
        }
    }

    // MARK: - 布局（确定性：无物理模拟，任何输入都给稳定画面）

    private func layoutPositions(mode: GraphMode, graph: MemoryGraph, in size: CGSize) -> [String: CGPoint] {
        switch mode {
        case .characters: return layoutCharacters(graph: graph, in: size)
        case .plot: return layoutPlot(graph: graph, in: size)
        case .events: return layoutEvents(graph: graph, in: size)
        }
    }

    /// 人物关系图：圆环布局，边粗细=关系事实数
    private func layoutCharacters(graph: MemoryGraph, in size: CGSize) -> [String: CGPoint] {
        let chars = (graph.byKind[.character] ?? [])
            .sorted { ($0.weight, $0.label) > ($1.weight, $1.label) }
        guard !chars.isEmpty else { return [:] }
        let radius = min(size.width, size.height) * 0.33
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var out: [String: CGPoint] = [:]
        for (i, c) in chars.enumerated() {
            let angle = 2 * Double.pi * Double(i) / Double(chars.count) - Double.pi / 2
            out[c.id] = CGPoint(
                x: center.x + radius * CGFloat(cos(angle)),
                y: center.y + radius * CGFloat(sin(angle)))
        }
        return out
    }

    /// 剧情图：故事线泳道，事件按章横向排布
    private func layoutPlot(graph: MemoryGraph, in size: CGSize) -> [String: CGPoint] {
        let lines = graph.byKind[.storyline] ?? []
        let events = graph.byKind[.event] ?? []
        guard !lines.isEmpty || !events.isEmpty else { return [:] }
        var out: [String: CGPoint] = [:]
        let top = size.height * 0.14
        let laneH = lines.isEmpty ? 0 : (size.height - top - 30) / CGFloat(max(1, lines.count))
        // 泳道 y
        for (i, s) in lines.enumerated() {
            out[s.id] = CGPoint(x: 46, y: top + laneH * CGFloat(i) + laneH / 2)
        }
        let maxChapter = max(1, (events.map { $0.chapter ?? 0 }.max() ?? 1))
        func xForChapter(_ ch: Int) -> CGFloat {
            90 + (size.width - 150) * CGFloat(ch) / CGFloat(maxChapter + 1)
        }
        for e in events {
            let ch = e.chapter ?? 0
            // 归属第一条故事线泳道；无归属铺在最下一条泳道
            let lane = laneIndex(of: e.id, in: lines, graph: graph)
            let y = lines.isEmpty
                ? size.height / 2
                : top + laneH * CGFloat(lane) + laneH / 2
            out[e.id] = CGPoint(x: xForChapter(ch), y: y)
        }
        return out
    }

    /// 事件图：章为横轴（升序），伏笔埋→揭画弧
    private func layoutEvents(graph: MemoryGraph, in size: CGSize) -> [String: CGPoint] {
        let events = (graph.byKind[.event] ?? []).sorted { ($0.chapter ?? 0) < ($1.chapter ?? 0) }
        let clues = graph.byKind[.clue] ?? []
        guard !events.isEmpty || !clues.isEmpty else { return [:] }
        let maxChapter = max(1, (events.map { $0.chapter ?? 0 }.max() ?? 1),
                             (clues.map { $0.chapter ?? 0 }.max() ?? 1))
        func xForChapter(_ ch: Int) -> CGFloat {
            70 + (size.width - 120) * CGFloat(ch) / CGFloat(maxChapter + 1)
        }
        var out: [String: CGPoint] = [:]
        // 事件：按章聚类到不同行（同章错开，避免重叠）
        var byChapter: [Int: [MemoryNode]] = [:]
        for e in events { byChapter[e.chapter ?? 0, default: []].append(e) }
        let midY = size.height * 0.52
        for (ch, evs) in byChapter {
            let x = xForChapter(ch)
            for (i, e) in evs.enumerated() {
                let spread = CGFloat(i - (evs.count - 1)) * 46
                out[e.id] = CGPoint(x: x, y: midY + spread)
            }
        }
        // 伏笔：埋设章下方一条轨
        for (i, c) in clues.enumerated() {
            let y = size.height * 0.85 - CGFloat(i % 4) * 26
            out[c.id] = CGPoint(x: xForChapter(c.chapter ?? 0), y: y)
        }
        return out
    }

    /// 事件在泳道里的归属：取 belongs 边第一条故事线；无归属归最后一条泳道
    private func laneIndex(of nodeID: String, in lines: [MemoryNode], graph: MemoryGraph) -> Int {
        for e in graph.edgesOf(nodeID) where e.kind == .belongs {
            if let idx = lines.firstIndex(where: { $0.id == e.to }) { return idx }
        }
        return max(0, lines.count - 1)
    }

    // MARK: - 绘制

    private func drawEdges(context: GraphicsContext, mode: GraphMode, graph: MemoryGraph, positions: [String: CGPoint]) {
        for e in graph.edges {
            guard let a = positions[e.from], let b = positions[e.to] else { continue }
            let visible: Bool
            switch e.kind {
            case .relation: visible = mode == .characters
            case .belongs: visible = mode == .plot && e.kind == .belongs
            case .coChapter: visible = mode == .plot && e.kind == .coChapter
            case .reveal: visible = mode == .events && e.kind == .reveal
            case .clueInChapter: visible = mode == .events && e.kind == .clueInChapter
            }
            guard visible else { continue }

            let color: Color
            switch e.kind {
            case .relation: color = .teal.opacity(0.55)
            case .belongs: color = .indigo.opacity(0.45)
            case .coChapter: color = .secondary.opacity(0.25)
            case .reveal: color = ZB.vermillion.opacity(0.5)
            case .clueInChapter: color = .orange.opacity(0.4)
            }
            var path = Path()
            if e.kind == .reveal {
                // 弧线（悬念链埋→揭）
                let mid = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 60)
                path.move(to: a)
                path.addQuadCurve(to: b, control: mid)
            } else {
                path.move(to: a)
                path.addLine(to: b)
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1 + CGFloat(e.weight) * 0.8,
                                              dash: e.kind == .coChapter ? [4, 3] : []))
            if e.kind == .relation {
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 6)
                context.draw(Text(e.label).font(.system(size: 9)).foregroundColor(.teal.opacity(0.8)),
                             at: mid, anchor: .center)
            }
        }
    }

    private func drawNodes(context: GraphicsContext, mode: GraphMode, graph: MemoryGraph, positions: [String: CGPoint]) {
        for node in graph.nodes {
            guard let p = positions[node.id] else { continue }
            let relevant: Bool
            switch mode {
            case .characters: relevant = node.kind == .character
            case .plot: relevant = node.kind == .event || node.kind == .storyline
            case .events: relevant = node.kind == .event || node.kind == .clue
            }
            guard relevant else { continue }

            let r = nodeRadius(node)
            let selected = node.id == selectedID
            let fill = nodeColor[node.kind] ?? .accentColor

            // 命中圈
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            if node.kind == .clue {
                var diamond = Path()
                diamond.move(to: CGPoint(x: p.x, y: p.y - r))
                diamond.addLine(to: CGPoint(x: p.x + r, y: p.y))
                diamond.addLine(to: CGPoint(x: p.x, y: p.y + r))
                diamond.addLine(to: CGPoint(x: p.x - r, y: p.y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(fill.opacity(selected ? 0.9 : 0.75)))
                context.stroke(diamond, with: .color(selected ? .white : .clear), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(fill.opacity(selected ? 0.95 : 0.8)))
                if selected {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                                   with: .color(.white), lineWidth: 2)
                }
            }
            // 标签
            let labelPos = CGPoint(x: p.x, y: p.y + r + 9)
            context.draw(
                Text(node.label)
                    .font(.system(size: node.kind == .storyline ? 11 : 9.5,
                                  weight: node.kind == .storyline ? .semibold : .regular))
                    .foregroundColor(.primary.opacity(0.85)),
                at: labelPos, anchor: .top)
        }
    }

    private func nodeRadius(_ node: MemoryNode) -> CGFloat {
        switch node.kind {
        case .character: return min(16, 6 + CGFloat(node.weight) * 0.7)
        case .storyline: return 7
        case .event: return 6
        case .clue: return 6
        }
    }

    private func nearestNode(_ point: CGPoint, positions: [String: CGPoint], threshold: CGFloat) -> String? {
        var best: (String, CGFloat)?
        for (id, p) in positions {
            let d = hypot(point.x - p.x, point.y - p.y)
            if d <= threshold, best == nil || d < best!.1 { best = (id, d) }
        }
        return best?.0
    }

    // MARK: - 回溯面板

    private var recallPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("全库回溯（人名/伏笔/任意词）", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            if !query.isEmpty {
                searchResults
            } else if let id = selectedID, let node = graph[id] {
                nodeRecall(node)
            } else {
                legendAndStats
            }
            Spacer()
        }
        .padding(12)
    }

    private var searchResults: some View {
        let items = MemoryRecall.search(query, store: store)
        return Group {
            if items.isEmpty {
                Text("没有命中。试试人名、伏笔标题或事件里的词。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("命中 \(items.count) 条，按章排序").font(.caption.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { recallList(items) }
                }
            }
        }
    }

    @ViewBuilder
    private func nodeRecall(_ node: MemoryNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(nodeColor[node.kind] ?? .accentColor).frame(width: 10, height: 10)
                Text(node.label).font(.headline)
                Text(node.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            if !node.meta.isEmpty {
                Text(node.meta).font(.caption).foregroundStyle(.secondary)
            }
            let links = graph.neighbors(node.id)
            if !links.isEmpty {
                Text("关联 \(links.count) 个实体").font(.caption.bold())
                HStack(spacing: 4) {
                    ForEach(links.prefix(8)) { n in
                        Button(n.label) { selectedID = n.id }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .lineLimit(1)
                    }
                }
            }
            Divider()
            let items = MemoryRecall.recall(node: node, store: store)
            if items.isEmpty {
                Text("这条实体还没有回溯记录。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("记忆回溯（\(items.count) 条）").font(.caption.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { recallList(items) }
                }
            }
        }
    }

    private func recallList(_ items: [RecallItem]) -> some View {
        ForEach(items) { item in
            HStack(alignment: .top, spacing: 8) {
                Text("第\(item.chapter)")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .font(.caption)
                        .strikethrough(item.expired)
                        .foregroundStyle(item.expired ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.sub.isEmpty {
                        Text(item.sub).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let target = item.target {
                        Button {
                            switch target {
                            case .chapter(let n): onGotoChapter(n)
                            case .clue: break
                            }
                        } label: {
                            if case .chapter(let n) = target {
                                Label("去第\(n)章", systemImage: "arrow.right.circle")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.link)
                        .controlSize(.mini)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 3)
        }
    }

    private var legendAndStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("交叉记忆").font(.headline)
            Text("图从账本机械派生：人物（记忆事实折叠）、事件（时间线）、伏笔（埋/推/兑现）、故事线。点任意节点看它的全链；顶部搜索做全库回溯。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            let chars = graph.byKind[.character]?.count ?? 0
            let evs = graph.byKind[.event]?.count ?? 0
            let cl = graph.byKind[.clue]?.count ?? 0
            let sl = graph.byKind[.storyline]?.count ?? 0
            Label("人物 \(chars)", systemImage: "person.2.fill").foregroundStyle(.teal).font(.caption)
            Label("事件 \(evs)", systemImage: "flag.fill").foregroundStyle(Color.accentColor).font(.caption)
            Label("伏笔 \(cl)", systemImage: "link").foregroundStyle(Color(ZB.vermillion)).font(.caption)
            Label("故事线 \(sl)", systemImage: "arrow.triangle.branch").foregroundStyle(.indigo).font(.caption)
            Divider()
            Text("拖拽平移 · 双指缩放 · 点节点回溯").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}


