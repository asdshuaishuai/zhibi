import Combine
import Foundation

// MARK: - 资料库索引 / 记忆检索
//
// 把散落在各处的书内资料（正文、设定、档案卡、伏笔、事实、时间线、故事线、阶段）
// 统一切成可检索的片段：
//   1. 关键词倒排 + BM25（零成本、离线可用）
//   2. 本地哈希向量（确定性，无网络也能做向量召回/重排）
//   3. 配置了 embeddingModel 时，用 OpenAI 兼容 /embeddings 远程向量重排
//
// 索引是派生缓存，不落盘；内容变了按 store 的签名自动重建。

enum KnowledgeKind: String, CaseIterable, Sendable {
    case canon = "设定"
    case prose = "正文"
    case summary = "章摘要"
    case skeleton = "骨架"
    case dossier = "档案卡"
    case clue = "伏笔"
    case fact = "记忆"
    case event = "时间线"
    case storyline = "故事线"
    case stage = "阶段"
}

/// 从 store 抽出的纯值资料源：主线程负责读取，后台负责切片/分词/向量化。
struct KnowledgeSource: Sendable {
    var kind: KnowledgeKind
    var title: String
    var citation: String
    var chapter: Int?
    var text: String
}

struct KnowledgeChunk: Identifiable, Sendable {
    var id: String
    var kind: KnowledgeKind
    var title: String
    /// 人读的来源标注，例如「第 12 章《雾隐》」「设定《世界观》」「伏笔 [F03] 断刀」
    var citation: String
    var chapter: Int?
    var text: String
    /// 本地哈希向量（构建索引时生成，用于离线语义召回/重排）
    var vector: [Float]
}

struct KnowledgeHit: Identifiable, Sendable {
    var id: String { chunk.id }
    var chunk: KnowledgeChunk
    var keywordScore: Double
    var score: Double
    var matchedTerms: [String]
}

/// 本次检索实际使用的向量通道：远程成功 / 远程失败已回退 / 未配置或未触发。
enum KnowledgeEmbeddingRun: Equatable, Sendable {
    case localOnly
    case remote
    case fallback
}

struct KnowledgeStats: Sendable {
    var chunks: Int
    var byKind: [KnowledgeKind: Int]
    var embeddingModel: String?
    var embeddingRun: KnowledgeEmbeddingRun?

    var embeddingLabel: String {
        guard let embeddingModel, !embeddingModel.isEmpty else {
            return "本地哈希向量（未配置嵌入模型）"
        }
        switch embeddingRun {
        case .remote:
            return "远程嵌入 · \(embeddingModel)"
        case .fallback:
            return "远程嵌入失败，已回退本地哈希向量"
        case .localOnly, .none:
            return "远程嵌入已配置 · \(embeddingModel)（本次检索未触发）"
        }
    }
}

// MARK: - 分词（中文双字滑窗 + 英文/数字整词）

enum KnowledgeTokenizer {
    static func tokens(_ text: String) -> [String] {
        var out = Set<String>()
        var buffer = ""
        func flush() {
            defer { buffer = "" }
            guard !buffer.isEmpty else { return }
            let chars = Array(buffer)
            let allHan = chars.allSatisfy(isHan)
            if allHan {
                if chars.count <= 8 { out.insert(buffer) }
                if chars.count >= 2 {
                    for i in 0..<(chars.count - 1) {
                        out.insert(String(chars[i...i + 1]))
                    }
                }
                if chars.count >= 3 {
                    for i in 0..<(chars.count - 2) {
                        out.insert(String(chars[i...i + 2]))
                    }
                }
            } else {
                // 英文/数字整词；混合段也保留整段与中文双字窗
                out.insert(buffer)
                if chars.count >= 2 {
                    for i in 0..<(chars.count - 1) where isHan(chars[i]) || isHan(chars[i + 1]) {
                        out.insert(String(chars[i...i + 1]))
                    }
                }
            }
        }
        for scalar in text.lowercased().unicodeScalars {
            let v = scalar.value
            let han = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            let alnum = (0x30...0x39).contains(v) || (0x61...0x7A).contains(v) || (0x41...0x5A).contains(v)
            if han || alnum {
                buffer.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return Array(out)
    }

    private static func isHan(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
}

// MARK: - 本地哈希向量（无网络也能用）

enum HashingVectorizer {
    static let dimensions = 256

    static func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        for token in KnowledgeTokenizer.tokens(text) {
            var hasher = Hasher()
            hasher.combine(token)
            let h = hasher.finalize()
            let idx = Int(UInt(bitPattern: h) % UInt(dimensions))
            let sign: Float = (h & 1) == 0 ? 1 : -1
            v[idx] += sign
        }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = sqrt(norm)
        if norm > 0 {
            for i in v.indices { v[i] /= norm }
        }
        return v
    }
}

enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (sqrt(na) * sqrt(nb)))
    }
}

// MARK: - 索引

struct KnowledgeIndex: Sendable {
    var chunks: [KnowledgeChunk] = []
    private var postings: [String: [Int]] = [:]
    private var chunkTerms: [[String: Int]] = []
    private var avgLength: Double = 1

    var kindCounts: [KnowledgeKind: Int] {
        var out: [KnowledgeKind: Int] = [:]
        for c in chunks { out[c.kind, default: 0] += 1 }
        return out
    }

    @MainActor
    static func sources(from store: ProjectStore) -> [KnowledgeSource] {
        var raw: [(KnowledgeKind, String, String, Int?, String)] = []

        for s in store.canonSections where !s.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw.append((.canon, "设定·\(s.title)", "设定《\(s.title)》", nil, s.content))
        }
        for ch in store.chapters where !ch.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = ch.title.isEmpty ? "第\(ch.number)章" : "第\(ch.number)章 \(ch.title)"
            raw.append((.prose, title, "第\(ch.number)章《\(ch.title.isEmpty ? "未命名" : ch.title)》", ch.number, ch.prose))
        }
        for ch in store.chapters {
            guard let summary = ch.summary,
                  !summary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let text = ([summary.summary] + summary.keyEvents + [summary.emotionalTone])
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            raw.append((.summary, "第\(ch.number)章摘要", "章摘要 第\(ch.number)章", ch.number, text))
        }
        for ch in store.chapters {
            guard let sk = ch.skeleton, !sk.beats.isEmpty else { continue }
            var lines: [String] = ["第\(ch.number)章「\(ch.title)」骨架（\(sk.humanApproved ? "作者已批准" : "尚未批准")）"]
            if let directive = ch.directive, !directive.isEmpty { lines.append("本章指令：\(directive)") }
            for b in sk.beats {
                var line = "- \(b.summary)（\(b.purpose)"
                if b.suggestedWords > 0 { line += "｜约\(b.suggestedWords)字" }
                line += "）"
                var scene: [String] = []
                if !b.pov.isEmpty { scene.append("视角：\(b.pov)") }
                if !b.location.isEmpty { scene.append("地点：\(b.location)") }
                if !b.timeLabel.isEmpty { scene.append("时间：\(b.timeLabel)") }
                if !b.cast.isEmpty { scene.append("在场：\(b.cast.joined(separator: "、"))") }
                if !b.turn.isEmpty { scene.append("转折：\(b.turn)") }
                if !scene.isEmpty { line += "｜" + scene.joined(separator: "｜") }
                lines.append(line)
            }
            if !sk.endHook.isEmpty { lines.append("章尾钩子：\(sk.endHook)" + (sk.hookKind.isEmpty ? "" : "（\(sk.hookKind)型）")) }
            if !sk.mustDeliver.isEmpty { lines.append("硬交付：" + sk.mustDeliver.joined(separator: "；")) }
            if !sk.mustAvoid.isEmpty { lines.append("禁止：" + sk.mustAvoid.joined(separator: "；")) }
            for t in sk.clueTouches {
                lines.append("伏笔触点：[\(t.clueID)] \(t.action.rawValue) —— \(t.requirement)")
            }
            raw.append((.skeleton, "第\(ch.number)章骨架", "骨架 第\(ch.number)章", ch.number,
                        lines.joined(separator: "\n")))
        }
        for d in store.dossiers {
            let text = ([d.headline] + d.scenes + d.cast + d.advances + d.turns + d.hooks + d.relics)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }
            raw.append((.dossier, "档案卡·第\(d.chapter)章", "档案卡 第\(d.chapter)章", d.chapter, text))
        }
        for c in store.clues {
            let text = "\(c.title)\n\(c.detail)\n\(c.plantedQuote)\n\(c.status.rawValue)"
            guard !c.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            raw.append((.clue, "伏笔 [\(c.id)] \(c.title)", "伏笔 [\(c.id)] \(c.title)", nil, text))
        }
        for f in store.facts where !f.subject.isEmpty && !f.object.isEmpty {
            let text = "\(f.subject) \(f.predicate) \(f.object)\n\(f.note)"
            raw.append((.fact, "记忆·\(f.subject) \(f.predicate)", "记忆账本·第\(f.fromChapter)章起", f.fromChapter, text))
        }
        for e in store.timelineEvents where !e.objectiveFact.isEmpty {
            let text = "\(e.objectiveFact)\n读者已知：\(e.readerKnowledge)"
            raw.append((.event, "时间线 [\(e.id)] 第\(e.chapter)章", "时间线 [\(e.id)]·第\(e.chapter)章", e.chapter, text))
        }
        for l in store.storylines where !l.name.isEmpty {
            let text = "\(l.name)\n\(l.kind.rawValue)\n\(l.status.rawValue)\n\(l.notes)"
            raw.append((.storyline, "故事线 [\(l.id)] \(l.name)", "故事线 [\(l.id)]", nil, text))
        }
        for s in store.stages where !s.name.isEmpty {
            let text = "\(s.name)\n\(s.theme)\n第\(s.chapterStart)-\(s.chapterEnd)章"
            raw.append((.stage, "阶段 \(s.name)", "阶段 第\(s.chapterStart)-\(s.chapterEnd)章", nil, text))
        }

        return raw.map {
            KnowledgeSource(kind: $0.0, title: $0.1, citation: $0.2, chapter: $0.3, text: $0.4)
        }
    }

    /// 纯值构建：只依赖传入的 sources，可以在后台任务里跑，不碰 store / MainActor。
    /// `onProgress` 给出 0...1 的确定进度（切片阶段到 0.9，倒排/收尾到 1）。
    static func build(from sources: [KnowledgeSource],
                      onProgress: (@Sendable (Double) -> Void)? = nil) -> KnowledgeIndex {
        let prepared = sources.map { ($0, split($0.text)) }
        let totalPieces = max(1, prepared.reduce(0) { $0 + $1.1.count })
        var completed = 0
        var idx = KnowledgeIndex()
        var chunkID = 0
        for (source, pieces) in prepared {
            // 被 invalidate / 新构建取代时尽快收手，别让旧任务继续啃百万字。
            if Task.isCancelled { return idx }
            for piece in pieces {
                completed += 1
                if completed % 64 == 0, Task.isCancelled { return idx }
                defer {
                    if completed % 24 == 0 || completed == totalPieces {
                        onProgress?(Double(completed) / Double(totalPieces) * 0.9)
                    }
                }
                let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard body.count >= 2 else { continue }
                let vector = HashingVectorizer.vector(source.title + "\n" + body)
                idx.chunks.append(KnowledgeChunk(id: "\(source.kind.rawValue)-\(chunkID)",
                                                 kind: source.kind, title: source.title,
                                                 citation: source.citation, chapter: source.chapter,
                                                 text: body, vector: vector))
                chunkID += 1
            }
        }

        idx.chunkTerms = idx.chunks.map { chunk in
            var counts: [String: Int] = [:]
            for token in KnowledgeTokenizer.tokens(chunk.title + "\n" + chunk.text) {
                counts[token, default: 0] += 1
            }
            return counts
        }
        for (i, counts) in idx.chunkTerms.enumerated() {
            for token in counts.keys {
                idx.postings[token, default: []].append(i)
            }
        }
        if !idx.chunks.isEmpty {
            idx.avgLength = Double(idx.chunks.reduce(0) { $0 + $1.text.count }) / Double(idx.chunks.count)
        }
        onProgress?(1.0)
        return idx
    }

    /// 同步便捷入口（自检 / 小书即时检索）；引擎走 `KnowledgeIndexCache.indexAsync`。
    @MainActor
    static func build(from store: ProjectStore) -> KnowledgeIndex {
        build(from: sources(from: store))
    }

    /// 按空行/段落聚合到约 600 字；单段过长再切开，避免一整章成为一个巨大片段。
    private static func split(_ text: String, target: Int = 600) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        var buffer = ""
        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            buffer = ""
        }
        for p in paragraphs {
            if p.count > target * 2 {
                flush()
                var start = p.startIndex
                while start < p.endIndex {
                    let end = p.index(start, offsetBy: target, limitedBy: p.endIndex) ?? p.endIndex
                    out.append(String(p[start..<end]))
                    start = end
                }
            } else if buffer.count + p.count + 2 > target, !buffer.isEmpty {
                flush()
                buffer = p
            } else {
                buffer += (buffer.isEmpty ? "" : "\n\n") + p
            }
        }
        flush()
        return out
    }

    func keywordSearch(_ query: String, limit: Int) -> [KnowledgeHit] {
        let tokens = KnowledgeTokenizer.tokens(query)
        guard !tokens.isEmpty, !chunks.isEmpty else { return [] }
        let n = Double(chunks.count)
        let k1 = 1.4
        let b = 0.72
        var scores: [Int: Double] = [:]
        var matched: [Int: Set<String>] = [:]
        for token in tokens {
            guard let posting = postings[token], !posting.isEmpty else { continue }
            let df = Double(posting.count)
            let idf = log(1 + (n - df + 0.5) / (df + 0.5))
            for i in posting {
                let tf = Double(chunkTerms[i][token] ?? 1)
                let dl = Double(chunks[i].text.count)
                let denom = tf + k1 * (1 - b + b * dl / max(avgLength, 1))
                let s = idf * (tf * (k1 + 1)) / max(denom, 0.0001)
                scores[i, default: 0] += s
                matched[i, default: []].insert(token)
            }
        }
        let qLower = query.lowercased()
        for i in scores.keys where chunks[i].title.lowercased().contains(qLower) {
            scores[i, default: 0] += 2.0
        }
        return scores.map { i, s in
            KnowledgeHit(chunk: chunks[i], keywordScore: s, score: s,
                         matchedTerms: Array(matched[i] ?? []).sorted())
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    func vectorFallback(_ query: String, limit: Int) -> [KnowledgeHit] {
        let qv = HashingVectorizer.vector(query)
        return chunks.map { c in
            KnowledgeHit(chunk: c, keywordScore: 0, score: VectorMath.cosine(qv, c.vector), matchedTerms: [])
        }
        .filter { $0.score > 0.12 }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }
}

// MARK: - 缓存 / 构建进度

/// 资料库页观察的后台构建进度。索引是派生数据，进度只影响“正在建立索引”的展示。
@MainActor
final class KnowledgeIndexProgress: ObservableObject {
    static let shared = KnowledgeIndexProgress()
    @Published var isBuilding = false
    @Published var fraction: Double = 0
    private init() {}
}

@MainActor
enum KnowledgeIndexCache {
    private static var cached: KnowledgeIndex?
    private static var cachedStamp = Int.min
    private static var buildTask: Task<KnowledgeIndex, Never>?
    private static var buildStamp = Int.min
    private static var buildGeneration = 0

    /// 同步入口：保留给自检与小书即时路径，不在主线程以外使用。
    static func index(for store: ProjectStore) -> KnowledgeIndex {
        let stamp = stamp(for: store)
        if let cached, cachedStamp == stamp { return cached }
        let built = KnowledgeIndex.build(from: store)
        cached = built
        cachedStamp = stamp
        return built
    }

    /// 异步入口：主线程只把 store 读成纯值快照，切片/分词/向量化放到后台。
    /// 百万字级书稿首次建索引不会再把界面卡住。
    static func indexAsync(for store: ProjectStore) async -> KnowledgeIndex {
        let currentStamp = stamp(for: store)
        if let cached, cachedStamp == currentStamp { return cached }
        if let buildTask, buildStamp == currentStamp { return await buildTask.value }

        let sources = KnowledgeIndex.sources(from: store)
        buildGeneration += 1
        let generation = buildGeneration
        KnowledgeIndexProgress.shared.isBuilding = true
        KnowledgeIndexProgress.shared.fraction = 0
        let task = Task.detached(priority: .userInitiated) {
            KnowledgeIndex.build(from: sources) { value in
                Task { @MainActor in
                    // 被 invalidate/新构建取代的旧任务不能再往新进度里写数。
                    guard buildGeneration == generation else { return }
                    let progress = KnowledgeIndexProgress.shared
                    progress.fraction = max(progress.fraction, value)
                }
            }
        }
        buildTask = task
        buildStamp = currentStamp
        let built = await task.value

        // 构建期间作者可能又改了正文：只接受仍然匹配当前内容的索引。
        if buildGeneration == generation, stamp(for: store) == currentStamp {
            cached = built
            cachedStamp = currentStamp
        }
        if buildGeneration == generation {
            buildTask = nil
            buildStamp = Int.min
            KnowledgeIndexProgress.shared.fraction = 1
            KnowledgeIndexProgress.shared.isBuilding = false
        }
        return built
    }

    static func invalidate() {
        buildTask?.cancel()
        buildTask = nil
        buildStamp = Int.min
        buildGeneration += 1
        KnowledgeIndexProgress.shared.isBuilding = false
        KnowledgeIndexProgress.shared.fraction = 0
        cached = nil
        cachedStamp = Int.min
    }

    private static func stamp(for store: ProjectStore) -> Int {
        // 不能只哈希长度：作者把「北境」改成「南境」这种同长度修订必须让索引失效，
        // 否则资料库会在整个进程生命周期里回放旧原文。这里哈希真实内容。
        var h = Hasher()
        h.combine(store.rootURL.standardizedFileURL.path)
        h.combine(store.canonSections.count)
        for s in store.canonSections {
            h.combine(s.title); h.combine(s.content)
            h.combine(s.category); h.combine(s.certainty.rawValue)
            h.combine(s.updatedAt.timeIntervalSince1970)
        }
        h.combine(store.chapters.count)
        for ch in store.chapters {
            h.combine(ch.number); h.combine(ch.title); h.combine(ch.prose)
            h.combine(ch.updatedAt.timeIntervalSince1970)
            if let sm = ch.summary {
                h.combine(sm.summary)
                for e in sm.keyEvents { h.combine(e) }
                h.combine(sm.emotionalTone)
            }
            if let sk = ch.skeleton {
                h.combine(sk.humanApproved); h.combine(sk.endHook); h.combine(sk.hookKind)
                h.combine(sk.pov); h.combine(sk.payoffType); h.combine(sk.newExpectation); h.combine(sk.volumeLabel)
                for b in sk.beats {
                    h.combine(b.summary); h.combine(b.purpose); h.combine(b.pov)
                    h.combine(b.location); h.combine(b.timeLabel); h.combine(b.turn)
                    h.combine(b.suggestedWords)
                    for c in b.cast { h.combine(c) }
                    for c in b.clueIDs { h.combine(c) }
                }
                for m in sk.mustDeliver { h.combine(m) }
                for m in sk.mustAvoid { h.combine(m) }
                for t in sk.clueTouches {
                    h.combine(t.clueID); h.combine(t.action.rawValue); h.combine(t.requirement)
                }
            }
        }
        h.combine(store.dossiers.count)
        for d in store.dossiers {
            h.combine(d.chapter); h.combine(d.searchText)
        }
        h.combine(store.clues.count)
        for c in store.clues {
            h.combine(c.id); h.combine(c.title); h.combine(c.detail); h.combine(c.plantedQuote)
            h.combine(c.status.rawValue); h.combine(c.plantedChapter); h.combine(c.lastActionChapter)
            h.combine(c.targetPayoffChapter ?? -1)
            for a in c.actions { h.combine(a.chapter); h.combine(a.kind.rawValue); h.combine(a.note) }
        }
        h.combine(store.facts.count)
        for f in store.facts {
            h.combine(f.subject); h.combine(f.predicate); h.combine(f.object)
            h.combine(f.fromChapter); h.combine(f.note); h.combine(f.publicToReader)
            h.combine(f.invalidatedAtChapter ?? -1)
        }
        h.combine(store.timelineEvents.count)
        for e in store.timelineEvents {
            h.combine(e.id); h.combine(e.objectiveFact); h.combine(e.readerKnowledge)
            h.combine(e.chapter); h.combine(e.revealed); h.combine(e.notes)
            h.combine(e.happened); h.combine(e.dropped); h.combine(e.actualChapter ?? -1)
        }
        h.combine(store.storylines.count)
        for l in store.storylines {
            h.combine(l.id); h.combine(l.name); h.combine(l.notes)
            h.combine(l.kind.rawValue); h.combine(l.status.rawValue); h.combine(l.isThroughLine)
        }
        h.combine(store.stages.count)
        for s in store.stages {
            h.combine(s.name); h.combine(s.theme)
            h.combine(s.chapterStart); h.combine(s.chapterEnd)
        }
        return h.finalize()
    }
}

// MARK: - 检索编排（关键词 + 向量重排）

@MainActor
enum KnowledgeEngine {
    static func search(store: ProjectStore, query: String, limit: Int = 8,
                       config: AgentConfig) async -> [KnowledgeHit] {
        await searchDetailed(store: store, query: query, limit: limit, config: config).hits
    }

    /// 带「本次向量通道」状态的检索：资料库页据此显示远程成功/失败回退。
    static func searchDetailed(store: ProjectStore, query: String, limit: Int = 8,
                               config: AgentConfig) async -> (hits: [KnowledgeHit], run: KnowledgeEmbeddingRun) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], .localOnly) }
        let index = await KnowledgeIndexCache.indexAsync(for: store)
        let candidates = index.keywordSearch(trimmed, limit: max(limit * 4, 24))
        if candidates.isEmpty {
            return (index.vectorFallback(trimmed, limit: limit), .localOnly)
        }
        let maxKeyword = candidates.map(\.keywordScore).max() ?? 1
        let queryVector = HashingVectorizer.vector(trimmed)
        var reranked = candidates.map { hit -> KnowledgeHit in
            var h = hit
            let cosine = VectorMath.cosine(queryVector, hit.chunk.vector)
            h.score = 0.75 * (hit.keywordScore / max(maxKeyword, 0.0001)) + 0.25 * max(0, cosine)
            return h
        }
        // 配了向量模型就走远程 embeddings 重排；失败/未配置则保留本地哈希结果。
        // EmbeddingService 会分批发送并缓存原文向量，候选多时也不会一次压爆端点。
        var run: KnowledgeEmbeddingRun = .localOnly
        if let model = config.embeddingModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty,
           candidates.count <= 48 {
            if let vectors = await EmbeddingService.embed(texts: [trimmed] + candidates.map(\.chunk.text),
                                                          config: config),
               vectors.count == candidates.count + 1 {
                run = .remote
                let qv = vectors[0]
                reranked = candidates.enumerated().map { i, hit in
                    var h = hit
                    let cosine = VectorMath.cosine(qv, vectors[i + 1])
                    h.score = 0.55 * (hit.keywordScore / max(maxKeyword, 0.0001)) + 0.45 * max(0, cosine)
                    return h
                }
            } else {
                run = .fallback
            }
        }
        return (Array(reranked.sorted { $0.score > $1.score }.prefix(limit)), run)
    }

    static func stats(store: ProjectStore, config: AgentConfig,
                      run: KnowledgeEmbeddingRun? = nil) async -> KnowledgeStats {
        let index = await KnowledgeIndexCache.indexAsync(for: store)
        return KnowledgeStats(chunks: index.chunks.count,
                              byKind: index.kindCounts,
                              embeddingModel: config.embeddingModel,
                              embeddingRun: run)
    }
}

// MARK: - 命中定位

enum KnowledgeFocus {
    /// 为一条资料命中挑一个能在原文里定位的针：优先最长命中词，其次正文前缀。
    static func needle(for hit: KnowledgeHit) -> String? {
        let text = hit.chunk.text
        let candidates = hit.matchedTerms
            .filter { $0.count >= 2 && text.contains($0) }
            .sorted { $0.count > $1.count }
        if let best = candidates.first { return best }
        let prefix = String(text.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.count >= 4 ? prefix : nil
    }

    static func range(of needle: String, in text: String) -> NSRange? {
        guard !needle.isEmpty, !text.isEmpty else { return nil }
        let range = (text as NSString).range(of: needle)
        return range.location == NSNotFound ? nil : range
    }
}

// MARK: - 回答来源对齐
//
// 模型回答里常写短标注（【第12章】【伏笔 [F03]】），资料库的完整标注更具体
// （「第12章《雾隐》」「伏笔 [F03] 断刀」）。UI 的引用芯片要能对齐到完整来源，
// 否则作者点开前后对不上；工具结果里的完整标注也要并进引用池。

enum KnowledgeCitationTarget: Equatable, Sendable {
    case chapter(Int)
    case canon
    case clues
    case memory
    case outline
}

enum KnowledgeCitations {
    /// 资料来源字符串 → 可跳转目标。UI 层再把它映射成工作区板块。
    static func target(for citation: String) -> KnowledgeCitationTarget? {
        let text = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("设定") { return .canon }
        if text.hasPrefix("伏笔") { return .clues }
        if text.hasPrefix("记忆") { return .memory }
        if text.hasPrefix("故事线") || text.hasPrefix("阶段") || text.hasPrefix("时间线") {
            return .outline
        }
        if let n = chapterNumber(in: text) { return .chapter(n) }
        return nil
    }

    /// 「第12章」「章摘要 第3章」「档案卡 第8章」→ 12 / 3 / 8
    static func chapterNumber(in text: String) -> Int? {
        guard let range = text.range(of: #"第(\d+)章"#, options: .regularExpression) else { return nil }
        let matched = text[range]
        return Int(matched.dropFirst().dropLast())
    }

    /// 提取【…】标注，保持出现顺序、去重。
    static func bracketed(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        var buffer: String?
        for ch in text {
            if ch == "【" {
                buffer = ""
            } else if ch == "】", let raw = buffer {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = nil
                guard value.count >= 2, value.count <= 80, !value.contains("\n") else { continue }
                if seen.insert(value).inserted { out.append(value) }
            } else if buffer != nil {
                buffer?.append(ch)
                // 异常长段落里出现的「【」不当作来源标注，避免把正文整段吞进来
                if (buffer?.count ?? 0) > 80 { buffer = nil }
            }
        }
        return out
    }

    /// 把回答里的短引用对齐到引用池里的完整来源；池里没有的保留模型原标注。
    static func resolve(in answer: String, pool: [String]) -> [String] {
        let refs = bracketed(in: answer)
        guard !refs.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for ref in refs {
            // 前缀匹配即可：「第12章」→「第12章《雾隐》」，「伏笔 [F03]」→「伏笔 [F03] 断刀」。
            // 反过来也允许，兼容池里只有短标注、回答写了长标注的情况。
            let match = pool.first { $0.hasPrefix(ref) || ref.hasPrefix($0) }
            let value = match ?? ref
            if seen.insert(value).inserted { out.append(value) }
        }
        return out
    }
}
