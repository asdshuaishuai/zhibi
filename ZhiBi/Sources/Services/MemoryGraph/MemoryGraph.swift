import Foundation

// MARK: - 记忆图引擎：交叉记忆机制的确定性核心
//
// 纪律（与全应用一致）：**只从现有账本机械派生，不新增任何存储**。
// 事实（双时态）/ 故事线 / 事件 / 伏笔 / 别名归一 全部来自 ProjectStore，
// 图引擎是它们的「关系视图」——改任何一处账本，图自动跟着变。
//
// 三种图谱共用同一套节点/边，按模式过滤：
// - 人物关系图：人物节点 + 关系事实边
// - 剧情图：故事线泳道 + 事件节点（归属/同章边）
// - 事件图：事件×章 时间轴 + 伏笔「埋→揭」弧

enum MemoryNodeKind: String, CaseIterable {
    case character = "人物"
    case storyline = "故事线"
    case event = "事件"
    case clue = "伏笔"
}

struct MemoryNode: Identifiable, Hashable {
    var id: String { "\(kind.rawValue)/\(key)" }
    let kind: MemoryNodeKind
    let key: String          // 人物名 / 故事线 id / 事件 id / 伏笔 id
    let label: String
    let chapter: Int?        // 主要章节（人物=最后一次出场，事件=发生章，伏笔=埋设章）
    let meta: String         // 一行摘要
    let weight: Int          // 连接数（布局大小用）

    var colorRole: String { kind.rawValue }
}

enum MemoryEdgeKind: String {
    case relation = "关系"       // 事实边：人物↔人物（predicate）
    case belongs = "归属"        // 事件→故事线
    case coChapter = "同章"      // 同章事件弱连
    case clueInChapter = "伏笔落章"  // 伏笔↔事件：动作章一致
    case reveal = "悬念链"        // 伏笔埋→揭
}

struct MemoryEdge: Identifiable, Hashable {
    var id: String { "\(from)|\(kind.rawValue)|\(to)|\(label)" }
    let from: String           // MemoryNode.id
    let to: String
    let kind: MemoryEdgeKind
    let label: String          // 谓词 / 故事线名 / 动作类型
    let weight: Int
}

struct MemoryGraph {
    var nodes: [MemoryNode] = []
    var edges: [MemoryEdge] = []

    subscript(nodeID: String) -> MemoryNode? { nodes.first { $0.id == nodeID } }

    var byKind: [MemoryNodeKind: [MemoryNode]] {
        Dictionary(grouping: nodes, by: \.kind)
    }

    /// 某节点的全部边（双向）
    func edgesOf(_ nodeID: String) -> [MemoryEdge] {
        edges.filter { $0.from == nodeID || $0.to == nodeID }
    }

    func neighbors(_ nodeID: String) -> [MemoryNode] {
        var ids: [String] = []
        for e in edges where e.from == nodeID || e.to == nodeID {
            let other = e.from == nodeID ? e.to : e.from
            if !ids.contains(other) { ids.append(other) }
        }
        return ids.compactMap { self[$0] }
    }

    /// 两节点间距离（BFS，用于回溯面板的「关联度」）
    func distance(from a: String, to b: String, maxSteps: Int = 3) -> Int? {
        if a == b { return 0 }
        var visited = Set([a])
        var frontier = [a]
        var step = 0
        while step < maxSteps, !frontier.isEmpty {
            step += 1
            var next: [String] = []
            for n in frontier {
                for e in edges where e.from == n || e.to == n {
                    let other = e.from == n ? e.to : e.from
                    if other == b { return step }
                    if !visited.contains(other) { visited.insert(other); next.append(other) }
                }
            }
            frontier = next
        }
        return nil
    }
}

// MARK: - 引擎：从 ProjectStore 派生

enum MemoryGraphEngine {
    @MainActor
    static func build(from store: ProjectStore) -> MemoryGraph {
        // 别名归一：alias → canonical
        var canonicalOf: [String: String] = [:]
        for a in store.characterAliases {
            for alias in a.aliases { canonicalOf[alias] = a.canonicalName }
        }
        func canon(_ name: String) -> String { canonicalOf[name] ?? name }

        let facts = store.facts
        // 人物集合：事实主语（归一后）+ 别名表 canonical
        var characterNames = Set<String>()
        for f in facts { characterNames.insert(canon(f.subject)) }
        for a in store.characterAliases { characterNames.insert(a.canonicalName) }

        var nodes: [MemoryNode] = []
        var edges: [MemoryEdge] = []

        // 人物节点
        var factsByCharacter: [String: [MemoryFact]] = [:]
        for f in facts {
            factsByCharacter[canon(f.subject), default: []].append(f)
        }
        for name in characterNames {
            let fs = factsByCharacter[name] ?? []
            let last = fs.map(\.fromChapter).max() ?? 0
            let relCount = fs.filter { $0.predicate == "关系" }.count
            nodes.append(MemoryNode(
                kind: .character, key: name, label: name, chapter: last,
                meta: "\(fs.count) 条事实" + (relCount > 0 ? " · \(relCount) 条关系" : ""),
                weight: 1 + fs.count))
        }

        // 故事线节点
        for s in store.storylines {
            nodes.append(MemoryNode(
                kind: .storyline, key: s.id, label: s.name,
                chapter: s.plannedPayoffChapter ?? s.entryChapter,
                meta: "\(s.kind.rawValue)\(s.isThroughLine ? " · 贯穿" : "")",
                weight: 2))
        }

        // 事件节点
        var eventsByChapter: [Int: [TimelineEvent]] = [:]
        for e in store.timelineEvents {
            eventsByChapter[e.chapter, default: []].append(e)
            let lineNames = e.storylineIDs.compactMap { lid in
                store.storylines.first { $0.id == lid }?.name
            }
            nodes.append(MemoryNode(
                kind: .event, key: e.id, label: "\(e.id) 第\(e.chapter)章",
                chapter: e.chapter,
                meta: String(e.objectiveFact.prefix(60)) + (lineNames.isEmpty ? "" : "｜\(lineNames.joined(separator: "/"))"),
                weight: 2))
            for lid in e.storylineIDs {
                edges.append(MemoryEdge(
                    from: "\(MemoryNodeKind.event.rawValue)/\(e.id)",
                    to: "\(MemoryNodeKind.storyline.rawValue)/\(lid)",
                    kind: .belongs,
                    label: store.storylines.first { $0.id == lid }?.name ?? lid, weight: 1))
            }
        }

        // 同章事件弱边（最多每章连 2 条链，防爆炸）
        for (_, evs) in eventsByChapter where evs.count >= 2 {
            let sorted = evs.sorted { $0.id < $1.id }
            for i in 0..<min(sorted.count - 1, 3) {
                edges.append(MemoryEdge(
                    from: "\(MemoryNodeKind.event.rawValue)/\(sorted[i].id)",
                    to: "\(MemoryNodeKind.event.rawValue)/\(sorted[i + 1].id)",
                    kind: .coChapter, label: "同章", weight: 1))
            }
        }

        // 伏笔节点 + 落章边 + 悬念链
        for c in store.clues {
            nodes.append(MemoryNode(
                kind: .clue, key: c.id, label: "\(c.id) \(c.title)",
                chapter: c.plantedChapter,
                meta: "埋于第\(c.plantedChapter)章 · \(c.status.rawValue)",
                weight: 2))
            // 伏笔动作落在哪些章 → 连到同章事件（弱边）
            var actionChapters = c.actions.map(\.chapter)
            if let target = c.targetPayoffChapter { actionChapters.append(target) }
            for ch in Set(actionChapters) {
                for e in eventsByChapter[ch] ?? [] {
                    edges.append(MemoryEdge(
                        from: "\(MemoryNodeKind.clue.rawValue)/\(c.id)",
                        to: "\(MemoryNodeKind.event.rawValue)/\(e.id)",
                        kind: .clueInChapter, label: "第\(ch)章动作", weight: 1))
                }
            }
            // 悬念链：埋设章事件 → 兑现章事件（读者视角的钩子闭合）
            if let target = c.targetPayoffChapter,
               let plantEvent = eventsByChapter[c.plantedChapter]?.first,
               let payEvent = eventsByChapter[target]?.first {
                edges.append(MemoryEdge(
                    from: "\(MemoryNodeKind.event.rawValue)/\(plantEvent.id)",
                    to: "\(MemoryNodeKind.event.rawValue)/\(payEvent.id)",
                    kind: .reveal, label: "\(c.id) 悬念链", weight: 2))
            }
        }

        // 关系边：人物↔人物（object 也是人物名时）
        let characterNodeIDs = Set(nodes.filter { $0.kind == .character }.map(\.id))
        var relationWeight: [String: Int] = [:]
        for f in facts where f.predicate == "关系" {
            let subj = canon(f.subject)
            let objName = canon(f.object)
            guard characterNames.contains(subj), characterNames.contains(objName), subj != objName else { continue }
            let from = "\(MemoryNodeKind.character.rawValue)/\(subj)"
            let to = "\(MemoryNodeKind.character.rawValue)/\(objName)"
            let key = [from, to].sorted().joined(separator: "↔")
            relationWeight[key, default: 0] += 1
        }
        // 一条谓词代表一种关系，多条合并成一条带权边
        var seenPair: Set<String> = []
        for f in facts where f.predicate == "关系" {
            let subj = canon(f.subject), objName = canon(f.object)
            guard characterNames.contains(subj), characterNames.contains(objName), subj != objName else { continue }
            let from = "\(MemoryNodeKind.character.rawValue)/\(subj)"
            let to = "\(MemoryNodeKind.character.rawValue)/\(objName)"
            let pairKey = [from, to].sorted().joined(separator: "↔")
            guard !seenPair.contains(pairKey) else { continue }
            seenPair.insert(pairKey)
            edges.append(MemoryEdge(
                from: from, to: to, kind: .relation,
                label: f.predicate, weight: relationWeight[pairKey] ?? 1))
        }

        // 事件→人物：objectiveFact 里提到人物名（字符串包含，弱边，最多 3 个/事件）
        // 名字 <2 字不参与包含匹配（「白」会误命中「李白」）；排序保证派生确定性
        let matchableNames = characterNames.filter { $0.count >= 2 }.sorted()
        for e in store.timelineEvents {
            var hits = 0
            for name in matchableNames where hits < 3 && e.objectiveFact.contains(name) {
                edges.append(MemoryEdge(
                    from: "\(MemoryNodeKind.event.rawValue)/\(e.id)",
                    to: "\(MemoryNodeKind.character.rawValue)/\(name)",
                    kind: .clueInChapter, label: "出场", weight: 1))
                hits += 1
            }
        }

        return MemoryGraph(nodes: nodes, edges: edges)
    }
}

// MARK: - 记忆回溯：任意实体的跨链全记录

/// 一条回溯条目（时间/性质/内容）
struct RecallItem: Identifiable {
    var id: String { "\(chapter)|\(kind.rawValue)|\(text.hashValue)" }
    enum Kind: String {
        case fact = "事实"
        case event = "事件"
        case clue = "伏笔"
        case summary = "章摘要"
    }
    let chapter: Int
    let kind: Kind
    let text: String
    let sub: String      // 次要信息（谓词/状态/线）
    let expired: Bool    // 双时态：是否已失效
    let target: RecallTarget?

    enum RecallTarget: Identifiable {
        case chapter(Int)
        case clue(String)
        var id: String {
            switch self {
            case .chapter(let n): return "ch\(n)"
            case .clue(let id): return "f\(id)"
            }
        }
    }
}

/// 某个节点（人物/事件/伏笔）的跨实体回溯：事实时间线 + 参与事件 + 关联伏笔
enum MemoryRecall {
    @MainActor
    static func recall(node: MemoryNode, store: ProjectStore) -> [RecallItem] {
        var out: [RecallItem] = []
        switch node.kind {
        case .character:
            let canonicalOf = Dictionary(store.characterAliases.flatMap { a in a.aliases.map { ($0, a.canonicalName) } },
                                         uniquingKeysWith: { first, _ in first })
            for f in store.facts where (canonicalOf[f.subject] ?? f.subject) == node.key {
                out.append(RecallItem(
                    chapter: f.fromChapter, kind: .fact,
                    text: "\(f.predicate) \(f.object)",
                    sub: f.invalidatedAtChapter.map { "第\($0)章起失效" } ?? (f.publicToReader ? "公开" : "暗线（读者未知）"),
                    expired: f.invalidatedAtChapter != nil,
                    target: .chapter(f.fromChapter)))
            }
        case .event:
            if let e = store.timelineEvents.first(where: { $0.id == node.key }) {
                out.append(RecallItem(
                    chapter: e.chapter, kind: .event,
                    text: "作者真相：\(e.objectiveFact)",
                    sub: "读者已知：\(e.readerKnowledge)（\(e.revealed ? "已揭晓" : "未揭晓\(e.revealChapter.map { "，第\($0)章揭晓" } ?? "")")）",
                    expired: false, target: .chapter(e.chapter)))
            }
        case .clue:
            if let c = store.clues.first(where: { $0.id == node.key }) {
                out.append(RecallItem(
                    chapter: c.plantedChapter, kind: .clue,
                    text: "埋下：\(c.title)——\(c.detail)",
                    sub: c.status.rawValue,
                    expired: false, target: .clue(c.id)))
                for a in c.actions.sorted(by: { $0.chapter < $1.chapter }) {
                    out.append(RecallItem(
                        chapter: a.chapter, kind: .clue,
                        text: "\(a.kind.rawValue)：\(a.note)",
                        sub: c.title, expired: false, target: .chapter(a.chapter)))
                }
            }
        case .storyline:
            for e in store.timelineEvents where e.storylineIDs.contains(node.key) {
                out.append(RecallItem(
                    chapter: e.chapter, kind: .event,
                    text: e.objectiveFact,
                    sub: e.revealed ? "已揭晓" : "未揭晓",
                    expired: false, target: .chapter(e.chapter)))
            }
        }
        return out.sorted { $0.chapter < $1.chapter }
    }

    /// 全库关键词回溯（人名/标题/任意词）——交叉记忆的检索入口
    @MainActor
    static func search(_ q: String, store: ProjectStore) -> [RecallItem] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var out: [RecallItem] = []
        // 别名扩展查询词：「少年」也要能翻出主语为「紫渊」的事实
        let canonicalOf = Dictionary(store.characterAliases.flatMap { a in a.aliases.map { ($0, a.canonicalName) } },
                                     uniquingKeysWith: { first, _ in first })
        var terms = [query]
        if let canonical = canonicalOf[query], !terms.contains(canonical) { terms.append(canonical) }
        for a in store.characterAliases where a.canonicalName == query || a.canonicalName.contains(query) {
            for alias in a.aliases where !terms.contains(alias) { terms.append(alias) }
        }
        for f in store.facts
        where terms.contains(where: { t in f.subject.contains(t) || f.object.contains(t) })
            || f.predicate.contains(query) {
            out.append(RecallItem(
                chapter: f.fromChapter, kind: .fact,
                text: "\(f.subject) \(f.predicate) \(f.object)",
                sub: f.invalidatedAtChapter.map { "第\($0)章起失效" } ?? "",
                expired: f.invalidatedAtChapter != nil,
                target: .chapter(f.fromChapter)))
        }
        for e in store.timelineEvents
        where e.objectiveFact.contains(query) || e.readerKnowledge.contains(query) {
            out.append(RecallItem(
                chapter: e.chapter, kind: .event,
                text: e.objectiveFact,
                sub: e.revealed ? "已揭晓" : "未揭晓",
                expired: false, target: .chapter(e.chapter)))
        }
        for c in store.clues
        where c.title.contains(query) || c.detail.contains(query) || c.plantedQuote.contains(query) {
            out.append(RecallItem(
                chapter: c.plantedChapter, kind: .clue,
                text: "\(c.title)：\(c.detail)",
                sub: c.status.rawValue,
                expired: false, target: .clue(c.id)))
        }
        return out.sorted { $0.chapter < $1.chapter }
    }
}
