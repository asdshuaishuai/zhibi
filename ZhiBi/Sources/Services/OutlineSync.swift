import Foundation

// MARK: - 大纲实时更新 + 剧情线连贯性引擎
//
// outline.json（故事线 L 编号 / 时间线事件 E 编号 / 阶段 Stage）是建书时一次性生成的静态计划。
// 章节推进后没人回头对账，它就会和真实剧情脱节：计划第 12 章的事推迟到第 18 章、某条支线
// 20 章没动过（断线）、某个阶段早该收束了。这里用确定性代码把「计划」与「实际」对齐：
//
//   事件排期 vs 摘要/正文  →  EventSync + 已发生/改期/取消/读者已知 提案
//   故事线的动静           →  LineHealth（健康/放缓/停滞/断线/待收束/已收束）
//   阶段边界 vs 实际进度   →  StageProgress + 阶段调整提案
//
// 产品铁律：AI/代码只提案，人裁决后才入库。所以本文件全程只读、绝不写盘，
// 只返回报告与建议，落库由宿主（提案收件箱）负责。零 LLM、可重复跑、结果确定。

/// 一条可被作者采纳的大纲更新（落库由宿主做，本模块只产出）
struct OutlineUpdate: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case eventHappened    = "事件已发生"
        case eventMoved       = "事件改期"
        case eventRevealed    = "读者已知"
        case eventDropped     = "事件取消"
        case storylineStatus  = "故事线状态"
        case stageAdjust      = "阶段调整"
    }
    var id: UUID = UUID()
    var kind: Kind = .eventHappened
    var eventID: String? = nil
    var storylineID: String? = nil
    var stageID: Int? = nil
    /// eventMoved 用（改到第几章）。eventRevealed 时承载「读者已知的章」，落库请写 revealChapter 而不是 chapter。
    var newChapter: Int? = nil
    var newStatusRaw: String? = nil   // storylineStatus 用（ActiveStatus.rawValue）
    var reason: String = ""           // 人话：凭什么这么判
    var evidence: String = ""         // 取证：命中的摘要/正文片段
    var confidence: Double = 0        // 0-1，模糊匹配得分
}

/// 剧情线健康档位（给作者看的人话标签，不是内部枚举）
enum LineState: String, Codable {
    case healthy = "健康"
    case slowing = "放缓"
    case stalled = "停滞"
    case broken  = "断线"
    case dueForPayoff = "待收束"
    case resolved = "已收束"
}

/// 一条故事线在 asOf 章的连贯性体检
struct LineHealth: Identifiable {
    var id: String { storylineID }
    var storylineID: String
    var name: String
    var kindRaw: String
    var isThroughLine: Bool
    var lastSeenChapter: Int          // 最后一次有实际动静的章（0 = 从未出现）
    var dormantChapters: Int          // asOf - lastSeen
    var plannedEvents: Int
    var matchedEvents: Int            // 计划事件里被正文/摘要证实已发生的数量
    var overdueEvents: Int            // 排期已过却没匹配上的事件数
    var state: LineState
    var note: String                  // 人话诊断
}

/// 一个计划事件的对账结果
struct EventSync: Identifiable {
    var id: String { eventID }
    var eventID: String
    var plannedChapter: Int
    var matchedChapter: Int?          // 实际发生在第几章（nil = 没找到）
    var status: String                // "已发生" / "未发生" / "疑似偏移" / "排期未到"
    var similarity: Double
    var evidence: String
}

/// 一个阶段的实际进度
struct StageProgress: Identifiable {
    var id: Int { stageID }
    var stageID: Int
    var name: String
    var chapterStart: Int
    var chapterEnd: Int
    var wordsWritten: Int
    var wordsPlanned: Int             // 章数 × project.chapterWordTarget
    var eventsTotal: Int
    var eventsDone: Int
    var completionRatio: Double       // 0-1，综合章数与事件完成度
    var note: String
}

/// 全书对账报告（只读产物，不落盘）
struct OutlineSyncReport {
    var asOfChapter: Int = 0
    var lineHealth: [LineHealth] = []
    var eventSync: [EventSync] = []
    var stageProgress: [StageProgress] = []
    var divergences: [ValidationIssue] = []   // 复用 ProposalModels 类型
    var suggestedUpdates: [OutlineUpdate] = []

    /// 一句话人话总结
    var summary: String {
        var parts: [String] = []
        if !eventSync.isEmpty {
            let done = eventSync.filter { $0.status == OutlineSync.statusHappened }.count
            let moved = eventSync.filter { $0.status == OutlineSync.statusShifted }.count
            let missed = eventSync.filter { $0.status == OutlineSync.statusMissed }.count
            parts.append("\(eventSync.count) 个计划事件里 \(done) 个已在正文里证实、\(moved) 个疑似改了章、\(missed) 个还没写")
        }
        let broken = lineHealth.filter { $0.state == .broken }.count
        let due = lineHealth.filter { $0.state == .dueForPayoff }.count
        if broken > 0 || due > 0 {
            var seg: [String] = []
            if broken > 0 { seg.append("\(broken) 条剧情线断线") }
            if due > 0 { seg.append("\(due) 条到了收束点还没收") }
            parts.append(seg.joined(separator: "、"))
        }
        let lagging = stageProgress.filter {
            asOfChapter > $0.chapterEnd && $0.completionRatio < OutlineSync.stageLagRatio
        }.count
        if lagging > 0 { parts.append("\(lagging) 个阶段进度落后") }

        guard !parts.isEmpty else {
            if asOfChapter <= 0 { return "还没有写出任何内容，暂时没有可对账的东西。" }
            return "对账到第\(asOfChapter)章：大纲和正文对得上，暂时不用改。"
        }
        var text = "对账到第\(asOfChapter)章：" + parts.joined(separator: "；") + "。"
        if !suggestedUpdates.isEmpty { text += "共 \(suggestedUpdates.count) 条大纲更新建议等你裁决。" }
        return text
    }
}

enum OutlineSync {

    // MARK: - 可调阈值（集中放这儿，按书的类型整体调松紧）

    /// 事件对账窗口：计划章前后各 N 章。剧情推迟/提前几章是常态，窗口太窄会漏判成「未发生」。
    static let eventWindow = 3
    /// ≥ 此分判「已发生」。摘要常常近乎原话复述计划事件，0.45 是双字组 Jaccard 的经验分界。
    static let matchedThreshold = 0.45
    /// 够不着 matchedThreshold 但 ≥ 此分 → 「疑似偏移」（有点关系，不敢替作者断定）
    static let shiftedThreshold = 0.25
    /// readerKnowledge 在正文里能对上这个分，就认为读者已经知道了
    static let revealedThreshold = 0.40
    /// 逾期多少章还没写 → 让作者决定「取消还是改期」
    static let dropOverdueChapters = 5
    /// 「读者已知」往后扫多少章：揭示通常紧跟事件发生，扫太远容易误命中别的段落
    static let revealLookahead = 12
    /// 正文只取前 N 字参与比对（再往后对本章事件的信息量递减，成本却线性上涨）
    static let proseHeadChars = 8000
    /// 取证片段截断长度
    static let evidenceChars = 60
    /// 句子超过这个字数就再按逗号切一层：整段参与 Jaccard 会把分母撑大，
    /// 局部命中永远上不了 0.45——不切开的话阈值就形同虚设。
    static let clauseSplitMinChars = 12
    /// 阶段进度低于此值却已经写过阶段末章 → 报阶段落后
    static let stageLagRatio = 0.6

    /// 各类偏差最多报几条（避免刷屏）
    static let maxLineIssues = 6
    static let maxEventIssues = 8
    static let maxStageIssues = 4
    static let maxOrphanIssues = 5

    // MARK: - 事件状态字面量（UI 与判定逻辑共用，别在别处手写字符串）

    static let statusHappened = "已发生"
    static let statusShifted = "疑似偏移"
    static let statusMissed = "未发生"
    static let statusFuture = "排期未到"

    // MARK: - 静默容忍度（多少章没动静算断线）

    static let dormantThroughLine = 3   // 贯穿线：造包时永不丢弃的那几条，断不得
    static let dormantMain = 3          // 主线
    static let dormantGrowth = 6        // 成长线 / 势力线：可以攒几章再爆
    static let dormantMid = 8           // 悬疑线 / 对手线 / 其他：允许埋伏期
    static let dormantSlowBurn = 12     // 感情线 / 世界线：本来就慢热

    // MARK: - 纯函数（无副作用、可单测、可被 CLI 自检直接调用）

    private static let skipScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    private static let clauseSeparators = CharacterSet(charactersIn: "，、：:—…")
    private static let nameSeparators = CharacterSet(charactersIn: "、，,·/／（）()【】[] 　:：;；")
    private static let namePieceSeparators = CharacterSet(charactersIn: "与和的及暨")

    /// 类别词：这些词在正文里到处都是，拿它当专名会把断线误判成健康
    private static let lineStopwords: Set<String> = [
        "线", "主线", "支线", "暗线", "明线", "伏线", "感情", "世界", "悬疑",
        "对手", "成长", "势力", "剧情", "其他", "副线",
    ]

    /// 去掉空白与标点后的可比字符序列（中文按 Character 计，保留字素簇）
    private static func comparableChars(_ s: String) -> [Character] {
        Array(s.filter { ch in ch.unicodeScalars.allSatisfy { !skipScalars.contains($0) } })
    }

    /// 中文双字组集合（bigram）
    private static func bigramSet(_ chars: [Character]) -> Set<String> {
        guard chars.count >= 2 else { return [] }
        var set = Set<String>()
        set.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i + 1])) }
        return set
    }

    private static func bigramSet(of s: String) -> Set<String> { bigramSet(comparableChars(s)) }

    /// 纯函数：中文双字组 Jaccard 相似度。空串 0，全同 1。
    static func similarity(_ a: String, _ b: String) -> Double {
        let ca = comparableChars(a)
        let cb = comparableChars(b)
        if ca.isEmpty || cb.isEmpty { return 0 }
        // 单字没有双字组可比：退化成「完全相同才算 1」
        if ca.count < 2 || cb.count < 2 { return ca == cb ? 1 : 0 }
        return jaccard(bigramSet(ca), bigramSet(cb))
    }

    /// 短边至少要有这么多双字组才启用包含度，否则两三个字的碎片到处都能"被完全覆盖"
    static let containmentMinBigrams = 4
    /// 包含度的折扣：满分也只给 0.85，压在 matchedThreshold 之上，
    /// 但不至于让「短边被完全覆盖」和「两边几乎一模一样」拿同样的分
    static let containmentWeight = 0.85

    /// 对账用的匹配打分。计划事件是一句话梗概、正文是展开的句子，两者体量天然不对等，
    /// 纯 Jaccard 会被长度差惩罚——实测「少年捡到断刀」对「少年在废窑里捡到一把断刀」只有 0.23，
    /// 够不着 0.25 的门槛，于是明明写了的事件被判成「未发生」。
    /// 包含度回答的才是对账真正要问的问题：计划里说的这几件事，正文是不是都写了。
    /// 纯函数，可直接单测。
    static func matchScore(fact: Int, unit: Int, intersection: Int) -> Double {
        guard fact > 0, unit > 0, intersection > 0 else { return 0 }
        let union = fact + unit - intersection
        let jac = union > 0 ? Double(intersection) / Double(union) : 0
        let shorter = min(fact, unit)
        guard shorter >= containmentMinBigrams else { return jac }
        return max(jac, Double(intersection) / Double(shorter) * containmentWeight)
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var inter = 0
        if a.count <= b.count {
            for g in a where b.contains(g) { inter += 1 }
        } else {
            for g in b where a.contains(g) { inter += 1 }
        }
        guard inter > 0 else { return 0 }
        let union = a.count + b.count - inter
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    /// 纯函数：判断一条故事线在 asOf 章的静默多少章算「断线」。
    /// 主线/贯穿线容忍度低（3 章），支线按类型放宽（感情线/世界线可更久）。
    static func dormantThreshold(kind: StorylineKind, isThroughLine: Bool) -> Int {
        // 贯穿线无论挂在哪一类，都是「不许断」的层级
        if isThroughLine { return dormantThroughLine }
        switch kind {
        case .main: return dormantMain
        case .growth, .faction: return dormantGrowth
        case .mystery, .rivalry, .other: return dormantMid
        case .romance, .world: return dormantSlowBurn
        }
    }

    // MARK: - 内部结构：比对单元缓存

    /// 一个可比对片段（摘要句 / 正文子句）+ 它的双字组集合
    private struct Unit {
        var text: String
        var bigrams: Set<String>
    }

    /// 一章的比对单元：摘要层优先，正文层兜底
    private struct ChapterUnits {
        var summaryUnits: [Unit] = []
        var proseUnits: [Unit] = []
    }

    /// 一次匹配的最好成绩
    private struct Match {
        var chapter: Int
        var score: Double
        var evidence: String
        static let none = Match(chapter: 0, score: 0, evidence: "")
    }

    /// 取证片段：压掉换行、截断到 evidenceChars
    private static func clip(_ s: String, _ limit: Int = OutlineSync.evidenceChars) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit)) + "…"
    }

    /// 把文本切成可比对单元：先按句读切，长句再按逗号切一层。
    /// 单元要「小」，Jaccard 的分母才不会被整段撑爆（否则阈值永远够不着）。
    private static func splitUnits(_ text: String) -> [Unit] {
        guard !text.isEmpty else { return [] }
        var out: [Unit] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, !seen.contains(t) else { return }
            let g = bigramSet(of: t)
            guard !g.isEmpty else { return }   // 只剩标点的片段没有比对意义
            seen.insert(t)
            out.append(Unit(text: t, bigrams: g))
        }
        for line in text.components(separatedBy: .newlines) {
            for sentence in line.splitChineseSentences() {
                add(sentence)
                guard sentence.count > clauseSplitMinChars else { continue }
                for clause in sentence.components(separatedBy: clauseSeparators) { add(clause) }
            }
        }
        return out
    }

    /// 在一批单元里找与 fact 最像的一条
    private static func bestMatch(_ fact: Set<String>, in units: [Unit], chapter: Int, label: String) -> Match {
        guard !fact.isEmpty, !units.isEmpty else { return .none }
        let fCount = fact.count
        var best = Match.none
        for u in units {
            let uCount = u.bigrams.count
            guard uCount > 0 else { continue }
            // 剪枝：交集最多 min(|A|,|B|)。上界要同时覆盖 Jaccard 与包含度两条路，
            // 只按 Jaccard 算会把体量悬殊但确实命中的单元提前剪掉。
            let shorter = min(fCount, uCount)
            let upper = max(Double(shorter) / Double(max(fCount, uCount)),
                            shorter >= containmentMinBigrams ? containmentWeight : 0)
            guard upper > best.score else { continue }
            var inter = 0
            if fCount <= uCount {
                for g in fact where u.bigrams.contains(g) { inter += 1 }
            } else {
                for g in u.bigrams where fact.contains(g) { inter += 1 }
            }
            guard inter > 0 else { continue }
            let score = matchScore(fact: fCount, unit: uCount, intersection: inter)
            if score > best.score {
                best = Match(chapter: chapter, score: score, evidence: "\(label)：\(clip(u.text))")
            }
        }
        return best
    }

    /// 摘要优先、正文兜底：摘要够硬就直接采信，不够硬才让正文片段参与竞争
    private static func chapterScore(_ fact: Set<String>, _ units: ChapterUnits, _ chapter: Int) -> Match {
        let s = bestMatch(fact, in: units.summaryUnits, chapter: chapter, label: "摘要")
        if s.score >= matchedThreshold { return s }
        let p = bestMatch(fact, in: units.proseUnits, chapter: chapter, label: "正文")
        return p.score > s.score ? p : s
    }

    /// 跨章择优：分高者胜；同分取离计划章更近的；再同取章号小的（保证结果可复现）
    private static func better(_ a: Match, _ b: Match, planned: Int) -> Match {
        if b.score > a.score { return b }
        guard b.score == a.score, b.score > 0 else { return a }
        let da = abs(a.chapter - planned), db = abs(b.chapter - planned)
        if db < da { return b }
        if db == da && b.chapter < a.chapter { return b }
        return a
    }

    /// 默认基准章 = 最后一章真有内容的章。不用 store.currentChapter：它指向「下一章」，
    /// 会把还没到期的排期事件误判成逾期。
    @MainActor
    private static func defaultAsOf(_ store: ProjectStore) -> Int {
        store.chapters.filter { !$0.prose.isEmpty || $0.summary != nil }.map(\.number).max() ?? 0
    }

    /// 专名池：既有人物别名 + 事实主语。故事线名（如「白零与苏叶的感情线」）几乎不会逐字
    /// 出现在正文里，真正能定位一条线动静的是它涉及的人名/势力名。
    @MainActor
    private static func properNames(_ store: ProjectStore) -> [String] {
        var names: [String] = []
        for a in store.characterAliases {
            if (2...8).contains(a.canonicalName.count) { names.append(a.canonicalName) }
            names.append(contentsOf: a.aliases.filter { (2...8).contains($0.count) })
        }
        names.append(contentsOf: store.facts.map(\.subject).filter { (2...8).contains($0.count) })
        var seen = Set<String>()
        return Array(names.filter { seen.insert($0).inserted }.prefix(200))
    }

    /// 一条故事线的检索关键词：优先取「线名/备注里提到的专名」；
    /// 一个都没有（新书常见）才退回用线名切片，并丢掉「××线」这类类别词。
    private static func lineKeywords(_ line: Storyline, namePool: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func push(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...12).contains(t.count), !seen.contains(t), !lineStopwords.contains(t) else { return }
            seen.insert(t)
            out.append(t)
        }
        let haystack = line.name + "\n" + line.notes
        for nm in namePool where haystack.contains(nm) { push(nm) }
        if out.isEmpty {
            for part in line.name.components(separatedBy: nameSeparators) {
                let core = part.hasSuffix("线") ? String(part.dropLast()) : part
                guard core != line.kind.rawValue else { continue }
                if (2...12).contains(core.count) { push(core) }
                // 「白零与苏叶的感情」这类连写名，再按连词切一刀
                for piece in core.components(separatedBy: namePieceSeparators) where (2...4).contains(piece.count) {
                    push(piece)
                }
            }
        }
        return Array(out.prefix(8))
    }

    // MARK: - 全书对账

    /// 计划 vs 实际对账（确定性，零 LLM，只读不写盘）。
    @MainActor
    static func sync(store: ProjectStore, asOfChapter n: Int? = nil) -> OutlineSyncReport {
        var report = OutlineSyncReport()
        let asOf = max(0, n ?? defaultAsOf(store))
        report.asOfChapter = asOf

        let chapters = store.chapters
        let events = store.timelineEvents
        let lines = store.storylines
        let clues = store.clues
        let stages = store.stages
        let wordTarget = max(1, store.project.chapterWordTarget)

        var updates: [OutlineUpdate] = []
        var divergences: [ValidationIssue] = []
        var lineIssueCount = 0, eventIssueCount = 0, stageIssueCount = 0, orphanIssueCount = 0, hidden = 0
        func addLineIssue(_ i: ValidationIssue) {
            if lineIssueCount < maxLineIssues { lineIssueCount += 1; divergences.append(i) } else { hidden += 1 }
        }
        func addEventIssue(_ i: ValidationIssue) {
            if eventIssueCount < maxEventIssues { eventIssueCount += 1; divergences.append(i) } else { hidden += 1 }
        }
        func addStageIssue(_ i: ValidationIssue) {
            if stageIssueCount < maxStageIssues { stageIssueCount += 1; divergences.append(i) } else { hidden += 1 }
        }
        func addOrphanIssue(_ i: ValidationIssue) {
            if orphanIssueCount < maxOrphanIssues { orphanIssueCount += 1; divergences.append(i) } else { hidden += 1 }
        }

        // ---- 1. 故事线关键词（信号 b 用）----
        let namePool = properNames(store)
        var keywordsByLine: [String: [String]] = [:]
        var lineIDsByNeedle: [String: [String]] = [:]
        for line in lines {
            let kws = lineKeywords(line, namePool: namePool)
            keywordsByLine[line.id] = kws
            for k in kws { lineIDsByNeedle[k, default: []].append(line.id) }
        }
        let allNeedles = lineIDsByNeedle.keys.sorted()

        // ---- 2. 单遍扫章：线名/专名最后出现在第几章 ----
        // 正文不进缓存（省内存），只在这一遍里就地做子串命中；越往后扫，记录的就是「最近一次」。
        var mentionChapter: [String: Int] = [:]
        if !allNeedles.isEmpty {
            for ch in chapters where ch.number <= asOf {
                var text = String(ch.prose.prefix(proseHeadChars))
                if let s = ch.summary {
                    text += "\n" + s.summary + "\n" + s.keyEvents.joined(separator: "\n")
                }
                guard !text.isEmpty else { continue }
                for needle in allNeedles where text.contains(needle) {
                    for id in lineIDsByNeedle[needle] ?? [] {
                        mentionChapter[id] = max(mentionChapter[id] ?? 0, ch.number)
                    }
                }
            }
        }

        // ---- 3. 事件对账 ----
        // 按章升序扫 + 滑动缓存：一章的比对单元只在它可能被用到的时候建一次，
        // 用完（后续事件的窗口再也够不着）就丢掉，内存与全书长度无关。
        var chapterByNumber: [Int: Chapter] = [:]
        for ch in chapters { if chapterByNumber[ch.number] == nil { chapterByNumber[ch.number] = ch } }
        var cache: [Int: ChapterUnits] = [:]
        func units(for c: Int) -> ChapterUnits? {
            if let hit = cache[c] { return hit }
            guard let ch = chapterByNumber[c] else { return nil }
            var summaryText = ""
            if let s = ch.summary {
                summaryText = s.summary + "\n" + s.keyEvents.joined(separator: "\n")
            }
            let built = ChapterUnits(summaryUnits: splitUnits(summaryText),
                                     proseUnits: splitUnits(String(ch.prose.prefix(proseHeadChars))))
            cache[c] = built
            return built
        }

        let byChapterID: (TimelineEvent, TimelineEvent) -> Bool = { ($0.chapter, $0.id) < ($1.chapter, $1.id) }
        let dueEvents = events.filter { $0.chapter <= asOf }.sorted(by: byChapterID)
        let futureEvents = events.filter { $0.chapter > asOf }.sorted(by: byChapterID)

        var syncs: [EventSync] = []
        var syncByEvent: [String: EventSync] = [:]

        for ev in dueEvents {
            // 作者已取消的事件不必再去正文里找（省掉整段比对开销），但仍列在报告里让他看得见
            let cancelled = ev.dropped
            let fact = cancelled ? Set<String>() : bigramSet(of: ev.objectiveFact)
            let wantReveal = !cancelled && !ev.revealed && !ev.readerKnowledge.isEmpty
            let revealFact = wantReveal ? bigramSet(of: ev.readerKnowledge) : Set<String>()

            let lo = max(1, ev.chapter - eventWindow)
            let hiMatch = min(asOf, ev.chapter + eventWindow)
            let hiReveal = wantReveal ? min(asOf, ev.chapter + revealLookahead) : 0
            let hi = max(hiMatch, hiReveal)

            var best = Match.none
            var revealBest = Match.none
            if lo <= hi, !fact.isEmpty || !revealFact.isEmpty {
                for c in lo...hi {
                    guard let u = units(for: c) else { continue }
                    if !fact.isEmpty, c <= hiMatch {
                        best = better(best, chapterScore(fact, u, c), planned: ev.chapter)
                    }
                    if !revealFact.isEmpty, c <= hiReveal {
                        revealBest = better(revealBest, chapterScore(revealFact, u, c), planned: ev.chapter)
                    }
                }
            }
            // 事件按章升序，后续窗口的下界只会更大：低于当前下界的缓存再也用不上
            let stale = cache.keys.filter { $0 < lo }
            for k in stale { cache[k] = nil }

            let status: String
            let matched: Int?
            if ev.happened {
                // 作者已经裁决过「这件事发生了」：台账优先于模糊匹配，别再拿正文得分推翻它
                status = statusHappened
                matched = ev.actualChapter ?? (best.score >= shiftedThreshold ? best.chapter : nil)
            } else if best.score >= matchedThreshold, best.chapter == ev.chapter {
                status = statusHappened; matched = best.chapter
            } else if best.score >= shiftedThreshold {
                // 分数够高但落在别的章 = 剧情推迟/提前了。这是作者最需要看见的偏移，
                // 归到「已发生」里会把「计划第3章、实际第6章」这个信息整个抹掉。
                status = statusShifted; matched = best.chapter
            } else {
                status = statusMissed; matched = nil
            }

            let sync = EventSync(eventID: ev.id, plannedChapter: ev.chapter, matchedChapter: matched,
                                 status: status, similarity: best.score,
                                 evidence: ev.dropped ? "作者已取消这个计划事件。" : (matched == nil ? "" : best.evidence))
            syncs.append(sync)
            syncByEvent[ev.id] = sync

            // --- 由此产出提案 ---
            // 已裁决过的（happened/dropped/actualChapter 有值）不再重复提案：
            // 这个对账会被反复跑，否则作者每跑一次就多一摞同样的建议。
            let settled = ev.happened || ev.dropped || ev.actualChapter != nil
            let factBrief = clip(ev.objectiveFact, 40)
            if let m = matched, status == statusHappened, !settled {
                let reason = m == ev.chapter
                    ? "第\(ev.chapter)章的\(evidenceSource(best.evidence))里能对上「\(factBrief)」，这条计划可以标记为已发生。"
                    : "「\(factBrief)」计划排在第\(ev.chapter)章，实际写在第\(m)章，建议按实际章号标记已发生。"
                // newChapter 只在真的偏移时给：宿主采纳时会把它写进 actualChapter
                updates.append(OutlineUpdate(kind: .eventHappened, eventID: ev.id,
                                             newChapter: m == ev.chapter ? nil : m,
                                             reason: reason, evidence: best.evidence, confidence: best.score))
            }
            if let m = matched, status == statusShifted, m != ev.chapter, !settled {
                updates.append(OutlineUpdate(kind: .eventMoved, eventID: ev.id, newChapter: m,
                                             reason: best.score >= matchedThreshold
                                                 ? "「\(factBrief)」计划排在第\(ev.chapter)章，但它实际是写在第\(m)章的（相似度 \(percent(best.score))，对得很实）。建议把这条事件改期到第\(m)章。"
                                                 : "「\(factBrief)」计划排在第\(ev.chapter)章，第\(m)章的内容与它对得最上（相似度 \(percent(best.score))），像是推迟或提前了；也可能是认错段落，你自己看一眼。",
                                             evidence: best.evidence, confidence: best.score))
            }
            var revealProposed = false
            if wantReveal, revealBest.score >= revealedThreshold {
                updates.append(OutlineUpdate(kind: .eventRevealed, eventID: ev.id, newChapter: revealBest.chapter,
                                             reason: "第\(revealBest.chapter)章的正文里已经写出了读者视角的这条信息，时间线上却还标着「读者不知道」。建议把揭示章记为第\(revealBest.chapter)章。",
                                             evidence: revealBest.evidence, confidence: revealBest.score))
                revealProposed = true
            }
            // 双时间线的意义就在于：事情写进正文，读者也就知道了。
            // readerKnowledge 通常和摘要措辞差很远，只靠它算相似度几乎命中不了，
            // 所以事件本身被证实发生、却仍标着「读者不知道」时，同样要提示补记揭示章。
            if !revealProposed, wantReveal, let m = matched, !ev.dropped {
                updates.append(OutlineUpdate(kind: .eventRevealed, eventID: ev.id, newChapter: m,
                                             reason: "第\(m)章的正文里已经写出了「\(factBrief)」，读者读到这里就已经知道了，时间线上却还标着「读者不知道」。建议把揭示章记为第\(m)章。",
                                             evidence: best.evidence, confidence: best.score))
            }
            let overdueBy = asOf - ev.chapter
            // 事件本身没写「作者真相」时无从对账，不能反过来说它没发生
            if status == statusMissed, !settled, !ev.objectiveFact.isEmpty, overdueBy > dropOverdueChapters {
                updates.append(OutlineUpdate(kind: .eventDropped, eventID: ev.id,
                                             reason: "「\(factBrief)」计划第\(ev.chapter)章发生，写到第\(asOf)章（逾期 \(overdueBy) 章）在摘要和正文里都找不到痕迹。要么取消，要么改期到后面——别让它一直挂在时间线上。",
                                             evidence: "",
                                             confidence: min(1.0, Double(overdueBy) / Double(dropOverdueChapters * 2))))
                addEventIssue(ValidationIssue(
                    severity: .warning, category: "时间线",
                    message: "[\(ev.id)] 计划第\(ev.chapter)章的「\(factBrief)」，写到第\(asOf)章还找不到痕迹（逾期 \(overdueBy) 章）",
                    evidence: "", suggestion: "确认是漏写了还是改期了：改期就把事件挪到新章，不写了就标记取消（记录会留着，不会删）。"))
            }
        }

        for ev in futureEvents {
            let sync = EventSync(eventID: ev.id, plannedChapter: ev.chapter, matchedChapter: nil,
                                 status: statusFuture, similarity: 0, evidence: "")
            syncs.append(sync)
            syncByEvent[ev.id] = sync
        }

        // ---- 4. 剧情线健康度 ----
        var health: [LineHealth] = []
        for line in lines.sorted(by: { $0.id < $1.id }) {
            let mine = events.filter { $0.storylineIDs.contains(line.id) }
            // 作者已取消的事件不再是计划的一部分（ContinuityAuditor 同样按 dropped 排除）
            let live = mine.filter { !$0.dropped }
            let droppedCount = mine.count - live.count
            var matchedCount = 0, overdueCount = 0, lastFromEvents = 0
            for e in live {
                guard let s = syncByEvent[e.id] else { continue }
                if s.status == statusHappened { matchedCount += 1 }
                else if s.plannedChapter <= asOf { overdueCount += 1 }
                if let m = s.matchedChapter { lastFromEvents = max(lastFromEvents, m) }
            }

            // 信号 c：关联伏笔的最近动作章（伏笔动了，线就还活着）
            let needles = keywordsByLine[line.id] ?? []
            var lastFromClues = 0
            if !needles.isEmpty {
                for c in clues {
                    guard needles.contains(where: { c.title.contains($0) || c.detail.contains($0) }) else { continue }
                    let act = max(c.lastActionChapter, c.plantedChapter, c.actions.map(\.chapter).max() ?? 0)
                    if act > 0, act <= asOf { lastFromClues = max(lastFromClues, act) }
                }
            }

            let lastSeen = max(lastFromEvents, mentionChapter[line.id] ?? 0, lastFromClues)
            let dormant = lastSeen == 0 ? asOf : max(0, asOf - lastSeen)
            let threshold = dormantThreshold(kind: line.kind, isThroughLine: line.isThroughLine)
            let kindName = line.kind.rawValue
            let payoff = line.plannedPayoffChapter
            let notYetEntered = lastSeen == 0 && (line.entryChapter ?? 0) > asOf

            var state: LineState
            if line.status == .resolved {
                state = .resolved
            } else if notYetEntered {
                state = .healthy      // 还没到入场章：不能算断线，否则一开书全线飘红
            } else if dormant <= 1 {
                // 上一章才动过就是健康。基准章（最后一章有内容的章）通常还没生成摘要，
                // 所以 dormant 几乎恒 >= 1；若把健康档卡在 dormant == 0，主线会常年显示「放缓」，
                // 对账条永远飘橙，作者看两天就直接无视它了——告警失去意义比没有告警更糟。
                state = .healthy
            } else if dormant <= max(2, threshold / 2) {
                state = .slowing
            } else if dormant <= threshold {
                state = .stalled
            } else {
                state = .broken
            }
            // 待收束优先于其它一切档位（除了已收束与尚未入场）：都过收束点了，
            // 「多久没动」已经不是重点——哪怕这条线上一章才动过，逾期的账也得先还。
            if let p = payoff, p <= asOf, line.status != .resolved, !notYetEntered {
                state = .dueForPayoff
            }

            var note: String
            switch state {
            case .resolved:
                note = "已经收束，不再跟踪。"
            case .healthy:
                if notYetEntered {
                    note = "计划第\(line.entryChapter ?? 0)章才入场，还没写到。"
                } else if lastSeen == 0 {
                    note = "摘要和正文里还找不到这条线的动静。"
                } else {
                    note = "第\(lastSeen)章还有动静，节奏正常。"
                }
            case .slowing:
                note = "已经 \(dormant) 章没推进（\(kindName)最多容忍 \(threshold) 章），再拖就要断线。"
            case .stalled:
                note = "已经 \(dormant) 章没有动静，顶到\(kindName)的容忍上限（\(threshold) 章）了。"
            case .broken:
                note = "已经 \(dormant) 章没有任何动静，超过\(kindName)的容忍上限（\(threshold) 章）——断线了。"
            case .dueForPayoff:
                let p = payoff ?? asOf
                note = "计划第\(p)章收束，现在写到第\(asOf)章还没收（逾期 \(max(0, asOf - p)) 章）。"
            }
            if !live.isEmpty {
                note += " 计划 \(live.count) 个事件，正文里证实 \(matchedCount) 个"
                if overdueCount > 0 { note += "，\(overdueCount) 个已过排期还没写" }
                note += "。"
            }
            if droppedCount > 0 { note += " 另有 \(droppedCount) 个计划事件你已取消，不计入上面的账。" }

            health.append(LineHealth(storylineID: line.id, name: line.name, kindRaw: kindName,
                                     isThroughLine: line.isThroughLine, lastSeenChapter: lastSeen,
                                     dormantChapters: dormant, plannedEvents: live.count,
                                     matchedEvents: matchedCount, overdueEvents: overdueCount,
                                     state: state, note: note))

            // --- 偏差 + 提案 ---
            if state == .broken {
                addLineIssue(ValidationIssue(
                    severity: .warning, category: "剧情线",
                    message: "[\(line.id)]「\(line.name)」已经 \(dormant) 章没有任何动静（\(kindName)容忍上限 \(threshold) 章）——断线了",
                    evidence: note,
                    suggestion: "近几章里给它一个具体动作，或者显式标成蛰伏/已收束，别让读者把它忘了。"))
                if line.status == .active {
                    updates.append(OutlineUpdate(
                        kind: .storylineStatus, storylineID: line.id,
                        newStatusRaw: ActiveStatus.dormant.rawValue,
                        reason: "「\(line.name)」已经 \(dormant) 章没有任何动静，超过\(kindName)的容忍上限（\(threshold) 章）。先标成蛰伏，等你决定是推进还是砍掉。",
                        evidence: note,
                        confidence: min(1, Double(dormant) / Double(max(1, threshold * 2)))))
                }
            }
            if let p = payoff, p <= asOf, line.status != .resolved {
                let late = max(0, asOf - p)
                let head = "[\(line.id)]「\(line.name)」计划第\(p)章收束，现在写到第\(asOf)章（逾期 \(late) 章）"
                addLineIssue(ValidationIssue(
                    severity: late > threshold ? .warning : .note, category: "剧情线",
                    message: line.status == .active ? head + "，却还挂着「进行中」" : head + "还没收",
                    evidence: note,
                    suggestion: "确认是不是已经收了：收了就改状态，没收就给它一个新的收束章。"))
                if state == .dueForPayoff {
                    updates.append(OutlineUpdate(
                        kind: .storylineStatus, storylineID: line.id,
                        newStatusRaw: ActiveStatus.resolved.rawValue,
                        reason: "「\(line.name)」计划第\(p)章收束，现在已经写到第\(asOf)章。如果实际上已经收束，就把状态改成已收束；没收就给它换一个新的收束章。",
                        evidence: note,
                        confidence: min(1, 0.4 + Double(late) / 20)))
                }
            }
        }

        // ---- 5. 阶段进度 ----
        var progress: [StageProgress] = []
        for stage in stages.sorted(by: { $0.id < $1.id }) {
            let span = max(1, stage.chapterEnd - stage.chapterStart + 1)
            var words = 0
            for ch in chapters where ch.number >= stage.chapterStart && ch.number <= stage.chapterEnd {
                words += ch.wordCount
            }
            let plannedWords = span * wordTarget
            // 作者已取消的事件不进分母：它永远不会「完成」，留在里面会把阶段进度永久压低
            let inRange = events.filter {
                !$0.dropped && $0.chapter >= stage.chapterStart && $0.chapter <= stage.chapterEnd
            }
            // 只把强证据（已发生）算作完成：疑似偏移的把握不够，算进去会让阶段进度虚高
            let done = inRange.filter { syncByEvent[$0.id]?.status == statusHappened }.count

            let writtenChapters = min(asOf, stage.chapterEnd) - stage.chapterStart + 1
            let chapterProgress = min(1, max(0, Double(writtenChapters) / Double(span)))
            let wordRatio = plannedWords > 0 ? min(1, Double(words) / Double(plannedWords)) : 0
            // 阶段里一个事件都没排时，用字数当进度替身，否则这一半权重会白丢
            let eventProgress = inRange.isEmpty ? wordRatio : Double(done) / Double(inRange.count)
            let ratio = min(1, max(0, 0.5 * chapterProgress + 0.5 * eventProgress))

            var note: String
            if asOf < stage.chapterStart {
                note = "还没写到这一段（第\(stage.chapterStart)-\(stage.chapterEnd)章）。"
            } else {
                note = "第\(stage.chapterStart)-\(stage.chapterEnd)章：已写 \(words)/\(plannedWords) 字"
                if !inRange.isEmpty { note += "，计划 \(inRange.count) 个事件完成 \(done) 个" }
                note += "，进度 \(percent(ratio))。"
            }

            let lagging = asOf > stage.chapterEnd && ratio < stageLagRatio
            if lagging {
                let remaining = inRange.count - done
                let suggestedEnd = max(asOf, stage.chapterEnd + max(0, remaining))
                note += " 已经写到第\(asOf)章，阶段却只完成 \(percent(ratio))——边界该往后挪了。"
                addStageIssue(ValidationIssue(
                    severity: .warning, category: "阶段",
                    message: "第\(stage.id)阶段「\(stage.name.isEmpty ? "未命名" : stage.name)」计划到第\(stage.chapterEnd)章收尾，现在已经写到第\(asOf)章，进度只有 \(percent(ratio))",
                    evidence: note,
                    suggestion: "把阶段末章往后挪（按未完成事件数估到第\(suggestedEnd)章），或把没写的事件挪进下一阶段。"))
                updates.append(OutlineUpdate(
                    kind: .stageAdjust, stageID: stage.id, newChapter: suggestedEnd,
                    reason: "「\(stage.name.isEmpty ? "未命名" : stage.name)」计划第\(stage.chapterStart)-\(stage.chapterEnd)章，实际写到第\(asOf)章时进度只有 \(percent(ratio))（\(words)/\(plannedWords) 字，事件 \(done)/\(inRange.count)）。建议把末章挪到第\(suggestedEnd)章左右，或把没写的事件挪进下一阶段。",
                    evidence: note,
                    confidence: min(1, 1 - ratio)))
            }

            progress.append(StageProgress(stageID: stage.id, name: stage.name,
                                          chapterStart: stage.chapterStart, chapterEnd: stage.chapterEnd,
                                          wordsWritten: words, wordsPlanned: plannedWords,
                                          eventsTotal: inRange.count, eventsDone: done,
                                          completionRatio: ratio, note: note))
        }

        // ---- 6. 孤儿引用：事件挂在不存在的 L 编号上 ----
        // 一条故事线都没有的书不查（那时真正的问题是「没建线」，逐条报孤儿只会刷屏）
        if !lines.isEmpty {
            let knownLines = Set(lines.map(\.id))
            for ev in events.sorted(by: byChapterID) {
                let orphans = ev.storylineIDs.filter { !knownLines.contains($0) }
                guard !orphans.isEmpty else { continue }
                addOrphanIssue(ValidationIssue(
                    severity: .warning, category: "剧情线",
                    message: "[\(ev.id)] 第\(ev.chapter)章的事件挂在不存在的故事线 \(orphans.joined(separator: "、")) 上",
                    evidence: clip(ev.objectiveFact, 40),
                    suggestion: "补建这条故事线，或把事件改挂到已有的线上——否则这条线的健康度统计不到它。"))
            }
        }

        if hidden > 0 {
            divergences.append(ValidationIssue(
                severity: .note, category: "大纲对账",
                message: "另有 \(hidden) 条同类问题没有逐条列出",
                evidence: "", suggestion: "先处理上面这些，再对账一次剩下的就会露出来。"))
        }

        report.eventSync = syncs
        report.lineHealth = health
        report.stageProgress = progress
        report.divergences = divergences.sorted {
            ($0.severity, $0.category, $0.message) < ($1.severity, $1.category, $1.message)
        }
        report.suggestedUpdates = updates
        return report
    }

    // MARK: - 文案小工具

    private static func percent(_ v: Double) -> String { "\(Int((min(1, max(0, v)) * 100).rounded()))%" }

    /// 从取证片段里取出来源（「摘要」/「正文」），拼人话时用
    private static func evidenceSource(_ evidence: String) -> String {
        evidence.hasPrefix("正文") ? "正文" : "摘要"
    }
}
