import Foundation

// MARK: - 长程记忆：跨全书的情节档案与检索
//
// 现有记忆（事实三元组/伏笔台账/摘要）能回答「现在是什么状态」，但回答不了
// 「第 12 章那个场景里到底发生了什么」「紫渊第一次用刀是在哪一章」——写到第
// 80 章时，前 70 章的细节没有任何检索路径。本模块补这一层：
//
// 1. ChapterDossier（章档案卡）：每章一张结构化卡片——场景、出场人物、推进、
//    情绪拐点、悬念、关键物件与台词。比 200 字摘要信息密度更高、可被检索。
// 2. DossierIndex（倒排索引）：实体 → 章、关键词 → 章，纯确定性（零 AI 成本）。
// 3. DossierRecall（召回）：给定查询（人物/物件/伏笔/主题），返回最相关的
//    历史章卡片，注入上下文包——这是「长程记忆」真正生效的通道。

// MARK: - 档案卡

struct ChapterDossier: Codable, Identifiable {
    var id: UUID = UUID()
    var chapter: Int = 0
    /// 一句话：这章发生了什么（≤60 字，检索命中时显示）
    var headline: String = ""
    /// 场景序列（地点/时间/氛围，2-5 条）
    var scenes: [String] = []
    /// 出场人物（含出场方式）
    var cast: [String] = []
    /// 剧情推进点（发生了什么不可逆的变化）
    var advances: [String] = []
    /// 情绪拐点（紧张/松弛/反转发生在哪里）
    var turns: [String] = []
    /// 本章埋下/推进/回收的悬念
    var hooks: [String] = []
    /// 关键物件与台词（可检索的具体细节——长程记忆的锚点）
    var relics: [String] = []
    var createdAt: Date = Date()

    /// 检索用全文（倒排索引入口）
    var searchText: String {
        ([headline] + scenes + cast + advances + turns + hooks + relics).joined(separator: "\n")
    }
}

// MARK: - 倒排索引（确定性构建，零 AI）

struct DossierIndex {
    /// 实体/词 → 章号集合
    private(set) var index: [String: Set<Int>] = [:]
    private(set) var dossiers: [Int: ChapterDossier] = [:]

    static func build(from list: [ChapterDossier]) -> DossierIndex {
        var idx = DossierIndex()
        for d in list {
            idx.dossiers[d.chapter] = d
            for token in Self.tokenize(d.searchText) {
                idx.index[token, default: []].insert(d.chapter)
            }
        }
        return idx
    }

    /// 中文分词：双字滑窗 + 完整实体名（人物/物件多为 2-4 字，双字窗召回率足够；
    /// 这是确定性索引，不做语义分词——语义层交给 AI 的 dossier 本身）
    static func tokenize(_ text: String) -> [String] {
        var tokens: Set<String> = []
        let cleaned = text.replacingOccurrences(of: "[\\s，。；：、！？「」『』（）()\\[\\]\"'—…·.,;:!?]",
                                                with: "\u{3000}", options: .regularExpression)
        for segment in cleaned.components(separatedBy: "\u{3000}") where segment.count >= 2 {
            let chars = Array(segment)
            // 完整片段（≤6 字，多为名字/物件）
            if chars.count <= 6 { tokens.insert(segment) }
            // 双字滑窗
            for i in 0..<(chars.count - 1) {
                tokens.insert(String(chars[i...i+1]))
            }
            // 三字滑窗（补三字名）
            if chars.count >= 3 {
                for i in 0..<(chars.count - 2) {
                    tokens.insert(String(chars[i...i+2]))
                }
            }
        }
        return Array(tokens)
    }

    /// 关键词召回：返回命中的章号（按命中词数降序）
    func search(_ query: String, limit: Int = 5, excludeChapter: Int? = nil) -> [ChapterDossier] {
        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return [] }
        var score: [Int: Int] = [:]
        for token in tokens {
            for ch in index[token] ?? [] where ch != excludeChapter {
                score[ch, default: 0] += 1
            }
        }
        return score.sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { dossiers[$0.key] }
    }

    /// 实体档案：某个人物/物件在所有章里的活动轨迹
    func entityTrace(_ name: String) -> [ChapterDossier] {
        (index[name] ?? index[name.lowercased()] ?? [])
            .sorted()
            .compactMap { dossiers[$0] }
    }

    /// 全书索引统计（记忆中枢展示用）
    var coverage: (chapters: Int, tokens: Int) {
        (dossiers.count, index.count)
    }

    // MARK: 共享缓存（stamp = 档案规模签名；同规模不重建）

    private static var cachedIndex: DossierIndex?
    private static var cacheStamp = Int.min

    static func cached(for dossiers: [ChapterDossier]) -> DossierIndex {
        // 签名含章号与内容长度：改内容也会失效，比纯 count 安全
        let stamp = dossiers.reduce(0) { $0 &+ $1.chapter &* 31 &+ $1.searchText.count }
        if let cachedIndex, cacheStamp == stamp { return cachedIndex }
        let built = build(from: dossiers)
        cachedIndex = built
        cacheStamp = stamp
        return built
    }
}

// MARK: - 召回结果（注入上下文包的形式）

struct DossierRecallResult {
    var dossiers: [ChapterDossier]
    var query: String

    var asBlock: String {
        guard !dossiers.isEmpty else { return "" }
        return dossiers.map { d in
            var lines = ["【第\(d.chapter)章】\(d.headline)"]
            if !d.cast.isEmpty { lines.append("出场：" + d.cast.joined(separator: "、")) }
            if !d.relics.isEmpty { lines.append("细节：" + d.relics.joined(separator: "；")) }
            if !d.hooks.isEmpty { lines.append("悬念：" + d.hooks.joined(separator: "；")) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

// MARK: - 召回编排：从当前章上下文推导查询，检索历史档案

enum DossierRecall {
    /// 为第 n 章组装长程召回。查询源按价值排序：
    /// 活跃伏笔（最该兑现的历史细节）> 本章骨架/指令 > 最近章 headline 的关键实体
    /// > 活跃人物（事实账本里的主要角色）。后两者保证「书里没有任何伏笔/骨架时
    /// 也能按人物与剧情把历史细节召回来」。
    @MainActor
    static func recall(store: ProjectStore, forChapter n: Int, limit: Int = 6) -> DossierRecallResult {
        let index = DossierIndex.cached(for: store.dossiers)
        guard !index.dossiers.isEmpty else { return DossierRecallResult(dossiers: [], query: "") }

        var queries: [String] = []
        // 1) 活跃伏笔
        for c in store.activeClues(currentChapter: n).prefix(5) {
            queries.append(c.title)
            if !c.plantedQuote.isEmpty { queries.append(String(c.plantedQuote.prefix(30))) }
        }
        // 2) 本章骨架节拍
        if let sk = store.chapter(n)?.skeleton {
            for beat in sk.beats.prefix(4) where !beat.summary.isEmpty { queries.append(beat.summary) }
        }
        // 3) 最近 3 章 headline（叙事连续性）
        let recent = store.dossiers.filter { $0.chapter < n }.sorted { $0.chapter > $1.chapter }.prefix(3)
        for d in recent { queries.append(d.headline) }
        // 4) 活跃人物（事实账本里出场最多/最近出现的角色名）——兜底召回源
        var subjectWeight: [String: Int] = [:]
        for f in store.facts where f.isValid(atChapter: n - 1) {
            subjectWeight[f.subject, default: 0] += f.fromChapter
        }
        for (subject, _) in subjectWeight.sorted(by: { $0.value > $1.value }).prefix(4) {
            queries.append(subject)
        }

        var seen = Set<Int>()
        var picked: [ChapterDossier] = []
        // 两轮：先精确查询词（≥2 命中词优先），再放宽到召回不足时按最近章补足
        for q in queries where !q.isEmpty {
            for d in index.search(q, limit: 3, excludeChapter: n) where !seen.contains(d.chapter) {
                seen.insert(d.chapter)
                picked.append(d)
            }
            if picked.count >= limit { break }
        }
        if picked.count < min(3, limit) {
            // 兜底：最近的、尚未入选的档案章（保持最少量的叙事连续性上下文）
            for d in store.dossiers.filter({ $0.chapter < n }).sorted(by: { $0.chapter > $1.chapter })
            where !seen.contains(d.chapter) {
                seen.insert(d.chapter)
                picked.append(d)
                if picked.count >= limit { break }
            }
        }
        return DossierRecallResult(dossiers: Array(picked.prefix(limit)), query: queries.prefix(8).joined(separator: "｜"))
    }

    /// 实体轨迹查询（记忆中枢「这个人物经历了什么」入口）
    @MainActor
    static func trace(store: ProjectStore, entity: String) -> [ChapterDossier] {
        DossierIndex.cached(for: store.dossiers).entityTrace(entity)
    }
}
