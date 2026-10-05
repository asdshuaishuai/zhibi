import Foundation

// MARK: - 全书连贯性审查 + 伏笔埋点修复
//
// 与 Validator 的分工：Validator 审「这一章写没写对」，这里审「整本书的账还对不对得上」。
// 纪律同前：零 LLM、只读 store、只出报告与「修复提案」，不写盘不改账——
// 光报告没有用，所以每条伏笔烂账都配一个可被作者一键采纳的 ClueFix。

// MARK: - 伏笔修复动作

/// 伏笔修复动作：一条可被作者一键采纳的账本修正
struct ClueFix: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case replant   = "补埋"     // 台账说埋了，正文里找不到 → 在指定章补一段可定位的埋设
        case retarget  = "改期"     // 目标兑现章已过 → 顺延到未来某章
        case resolve   = "回收"     // 正文其实已经兑现了 → 台账标记已回收
        case `defer`   = "搁置"     // 作者决定暂时不管 → 显式搁置，停止过期告警
        case abandon   = "放弃"     // 这条线不要了 → 显式放弃（比烂在账上强）
        case requote   = "校正种下原文" // plantedQuote 与正文不符 → 用正文里真实存在的片段替换
        case register  = "补登记"   // 正文疑似埋了点但台账没有 → 登记新伏笔
    }
    var id: UUID = UUID()
    var clueID: String = ""          // register 时为空
    var kind: Kind = .retarget
    var chapter: Int = 0             // 建议落点章
    var reason: String = ""          // 人话：为什么需要修
    var action: String = ""          // 人话：具体怎么修（可执行）
    var newStatus: String? = nil     // 采纳后写入的 ClueStatus.rawValue
    var newTimingRaw: String? = nil  // 采纳后写入的 ClueTiming.rawValue
    var newTargetChapter: Int? = nil
    var newQuote: String? = nil      // requote / register 用
    var newTitle: String? = nil      // register 用
    var newDetail: String? = nil     // register 用
    var evidence: String = ""        // 取证原文片段
}

// MARK: - 连贯性报告

struct ContinuityReport {
    var asOfChapter: Int = 0
    var issues: [ValidationIssue] = []   // 复用 ProposalModels 里的类型
    var clueFixes: [ClueFix] = []
    var scannedChapters: Int = 0

    /// 一句话人话总结（给顶栏/收件箱标题用）
    var summary: String {
        guard scannedChapters > 0 else { return "还没有可审的章节，先写第一章再来。" }
        let warnings = issues.filter { $0.severity == .warning }.count
        let notes = issues.filter { $0.severity == .note }.count
        var parts = ["审到第\(asOfChapter)章（扫描\(scannedChapters)章）"]
        if blockerCount > 0 { parts.append("\(blockerCount) 处必须处理") }
        if warnings > 0 { parts.append("\(warnings) 处要核对") }
        if notes > 0 { parts.append("\(notes) 条提醒") }
        if issues.isEmpty { parts.append("角色、时间线、伏笔台账都对得上") }
        if !clueFixes.isEmpty { parts.append("伏笔台账给出 \(clueFixes.count) 条可一键采纳的修复") }
        return parts.joined(separator: "，") + "。"
    }

    var blockerCount: Int { issues.filter { $0.severity == .blocker }.count }
}

// MARK: - 审查引擎

enum ContinuityAuditor {

    /// 匹配用正文上限（大书性能：不在循环里对全文做重复扫描）
    fileprivate static let proseCap = 20000
    /// 抽专名时每章只看开头这么多字（够用，且把成本压住）
    fileprivate static let nounScanCap = 6000
    /// 正文与台账「高度相似」的判定线
    fileprivate static let resolvedSimilarity = 0.5
    /// 种下原文「还认得出来」的最低相似度
    fileprivate static let quoteFoundSimilarity = 0.55
    /// 低于此值认为正文里根本没有这段埋设（不是改了字，是整段没了）
    fileprivate static let quoteHopeless = 0.3

    /// 全书连贯性审查（确定性，零 LLM 成本）。n 为 nil 时审到最后一章。
    @MainActor
    static func audit(store: ProjectStore, throughChapter n: Int? = nil) -> ContinuityReport {
        let lastChapter = store.chapters.map(\.number).max() ?? 0
        let asOf = n ?? lastChapter
        var report = ContinuityReport(asOfChapter: asOf)
        let corpus = ChapterCorpus(chapters: store.chapters, through: asOf)
        report.scannedChapters = corpus.numbers.count
        guard asOf > 0, !corpus.numbers.isEmpty else { return report }

        auditCharacters(store: store, corpus: corpus, asOf: asOf, report: &report)
        auditTimeline(store: store, corpus: corpus, asOf: asOf, report: &report)
        auditClueLedger(store: store, corpus: corpus, asOf: asOf, report: &report)
        auditStructure(store: store, corpus: corpus, asOf: asOf, report: &report)

        // 阻塞在前，同级保持发现顺序（Swift 的 sort 是稳定排序）
        report.issues.sort { $0.severity < $1.severity }
        // 修复按「先哪条线、再哪一章」排，方便作者顺着账本一条条采纳
        report.clueFixes.sort { lhs, rhs in
            let lk = lhs.clueID.isEmpty ? "\u{FFFF}" : lhs.clueID
            let rk = rhs.clueID.isEmpty ? "\u{FFFF}" : rhs.clueID
            if lk != rk { return lk < rk }
            return lhs.chapter < rhs.chapter
        }
        return report
    }

    // MARK: A. 角色连续性

    @MainActor
    private static func auditCharacters(store: ProjectStore, corpus: ChapterCorpus,
                                        asOf: Int, report: inout ContinuityReport) {
        // 1. 死者复出：死亡事实生效之后、失效之前，名字又出现在正文里
        var deathIssues = 0
        for fact in store.facts where fact.predicate == "死亡" {
            guard deathIssues < 6, fact.fromChapter > 0 else { continue }
            let subjectNames = names(for: fact.subject, aliases: store.characterAliases)
            guard !subjectNames.isEmpty else { continue }
            let subject = fact.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            // 记了失效章 = 作者已经承认复活/假死，那之后出场是合法的
            let revivedAt = fact.invalidatedAtChapter ?? Int.max
            guard revivedAt > fact.fromChapter else { continue }

            var hits: [(chapter: Int, sentence: String)] = []
            for num in corpus.numbers where num > fact.fromChapter && num < revivedAt {
                guard let sentence = firstRevivalSentence(in: corpus.sentences(num), names: subjectNames) else { continue }
                hits.append((chapter: num, sentence: sentence))
                if hits.count >= 3 { break }
            }
            guard let first = hits.first else { continue }
            deathIssues += 1
            let others = hits.dropFirst().map { String($0.chapter) }.joined(separator: "、")
            let extra = hits.count > 1 ? "，第\(others)章也一样" : ""
            report.issues.append(ValidationIssue(
                severity: .blocker, category: "连贯性",
                message: "「\(subject)」第\(fact.fromChapter)章就死了，第\(first.chapter)章却又出场了\(extra)",
                evidence: clip(first.sentence, 80),
                suggestion: "换成别人来说这句话；或明确写成回忆/追述；若真是复活，请在事实库给这条死亡补一个失效章。"))
        }

        // 2. 位置跳跃：相邻两章地点变了，中间却没有任何位移线索
        var jumpIssues = 0
        let located = store.facts.filter {
            $0.predicate == "位于" && $0.fromChapter > 0
                && !$0.object.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.subject.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let pairs = Dictionary(grouping: located, by: \.subject).flatMap { _, list -> [(MemoryFact, MemoryFact)] in
            let sorted = list.sorted { $0.fromChapter < $1.fromChapter }
            guard sorted.count >= 2 else { return [] }
            return (1..<sorted.count).compactMap { i in
                let a = sorted[i - 1], b = sorted[i]
                // 只看紧邻两章：跨多章的地点变化本来就允许发生；也不越过本次审查的进度线
                guard b.fromChapter == a.fromChapter + 1, b.fromChapter <= asOf, a.object != b.object else { return nil }
                return (a, b)
            }
        }.sorted { $0.0.fromChapter < $1.0.fromChapter }

        for (a, b) in pairs {
            guard jumpIssues < 5 else { break }
            if corpus.hasMovement(a.fromChapter, verbs: movementVerbs)
                || corpus.hasMovement(b.fromChapter, verbs: movementVerbs) { continue }
            let sentences = corpus.sentences(b.fromChapter)
            guard let ev = sentences.first(where: { $0.contains(b.object) || $0.contains(a.subject) }) else { continue }
            jumpIssues += 1
            report.issues.append(ValidationIssue(
                severity: .warning, category: "连贯性",
                message: "「\(a.subject)」第\(a.fromChapter)章还在\(a.object)，第\(b.fromChapter)章人就到了\(b.object)，中间没交代怎么过去的",
                evidence: clip(ev, 80),
                suggestion: "补一句位移（动身、赶路、被人带走都算），或改掉其中一条地点记录。"))
        }

        // 3. 人称漂移：同一个人，一部分章用别名、一部分章用本名，还有章两种混着用
        var driftIssues = 0
        for entry in store.characterAliases {
            guard driftIssues < 5 else { break }
            let canonical = entry.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fold(canonical).count >= 2 else { continue }
            for raw in entry.aliases {
                let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard fold(alias).count >= 2, alias != canonical else { continue }
                // 本名包含别名时（紫渊真人 / 紫渊），命中数要扣掉本名那部分，否则永远算「混用」
                let nested = canonical.contains(alias)
                var aliasOnly: [Int] = []
                var canonicalOnly: [Int] = []
                var mixed: [Int] = []
                for num in corpus.numbers {
                    let text = corpus.text(num)
                    guard !text.isEmpty else { continue }
                    let c = text.occurrences(of: canonical)
                    let a = text.occurrences(of: alias)
                    let alone = nested ? max(0, a - c) : a
                    if alone > 0 && c > 0 { mixed.append(num) }
                    else if alone > 0 { aliasOnly.append(num) }
                    else if c > 0 { canonicalOnly.append(num) }
                }
                guard !mixed.isEmpty, !aliasOnly.isEmpty, !canonicalOnly.isEmpty else { continue }
                let at = mixed[0]
                guard let ev = corpus.sentences(at).first(where: { $0.contains(alias) }) else { continue }
                driftIssues += 1
                report.issues.append(ValidationIssue(
                    severity: .note, category: "连贯性",
                    message: "「\(canonical)」的称呼在飘：第\(at)章里「\(canonical)」和「\(alias)」混着用，另有 \(aliasOnly.count) 章只叫「\(alias)」、\(canonicalOnly.count) 章只叫「\(canonical)」",
                    evidence: clip(ev, 80),
                    suggestion: "定一个主称呼，另一个只在特定视角或场合用，否则读者会当成两个人。"))
            }
        }
    }

    // MARK: B. 时间线

    @MainActor
    private static func auditTimeline(store: ProjectStore, corpus: ChapterCorpus,
                                      asOf: Int, report: inout ContinuityReport) {
        // 作者已取消的计划事件不参与审查（OutlineSync 用 dropped 标记，不删记录）
        let events = store.timelineEvents.filter { !$0.dropped }
        guard !events.isEmpty else { return }
        // 排期余量：已有章节数与作者立项的目标章数取大的那个
        let horizon = max(corpus.numbers.max() ?? asOf, store.project.targetChapters)

        // 4. 时间线倒挂：揭示章早于发生章
        var inversion = 0
        for e in events.sorted(by: { ($0.chapter, $0.id) < ($1.chapter, $1.id) }) {
            // 剧情偏移过时以实际发生章为准，否则会拿旧计划误判
            let happenedAt = e.actualChapter ?? e.chapter
            guard inversion < 8, let rc = e.revealChapter, rc < happenedAt else { continue }
            inversion += 1
            report.issues.append(ValidationIssue(
                severity: .warning, category: "时间线",
                message: "\(eventLabel(e))第\(happenedAt)章才发生，却标成第\(rc)章就告诉读者了",
                evidence: eventEvidence(e, fallback: "台账写的是：第\(happenedAt)章发生，第\(rc)章揭示"),
                suggestion: "把揭示章挪到发生章之后；若确实要提前透露，请在备注里写明这是有意安排的悬念倒置。"))
        }

        // 5. 事件排期越界
        let outside = events.filter { $0.chapter <= 0 || $0.chapter > horizon }
        if !outside.isEmpty {
            let ids = outside.prefix(5).map { $0.id.isEmpty ? "（未编号）" : $0.id }
            report.issues.append(ValidationIssue(
                severity: .note, category: "时间线",
                message: "\(outside.count) 条事件排在了书的外面（\(ids.joined(separator: "、"))\(outside.count > 5 ? "等" : "")）",
                evidence: outside.prefix(3).map { "第\($0.chapter)章：\(clip(firstNonEmpty([$0.objectiveFact, $0.readerKnowledge, $0.notes]), 40))" }.joined(separator: "；"),
                suggestion: "全书计划 \(store.project.targetChapters) 章、目前排到第 \(horizon) 章。把越界事件挪回范围内，或调高目标章数。"))
        }

        // 6. 「读者已知情」与揭示章对不上
        var mismatch = 0
        for e in events {
            guard mismatch < 8 else { break }
            let problem: String
            if e.revealed && e.revealChapter == nil {
                problem = "标了读者已知情，却没写是哪一章揭开的"
            } else if !e.revealed, let rc = e.revealChapter {
                problem = "写了第\(rc)章揭开，却没标读者已知情"
            } else { continue }
            mismatch += 1
            report.issues.append(ValidationIssue(
                severity: .warning, category: "时间线",
                message: "\(eventLabel(e))\(problem)",
                evidence: eventEvidence(e, fallback: "读者已知：\(e.revealed ? "是" : "否")；揭示章：\(e.revealChapter.map { String($0) } ?? "未填")"),
                suggestion: "两处对齐——读者知不知情、哪一章知道的，是控制悬念和信息差的唯一依据。"))
        }

        // 7. 同一件事被重复登记（只在真重复时报，避免同章多事件的正常噪音）
        var seen = Set<String>()
        var duplicated: [String] = []
        for e in events {
            let key = "\(e.id)|\(e.chapter)"
            guard !seen.insert(key).inserted else { continue }
            duplicated.append("\(e.id.isEmpty ? "（未编号）" : e.id)第\(e.chapter)章")
        }
        if !duplicated.isEmpty {
            report.issues.append(ValidationIssue(
                severity: .note, category: "时间线",
                message: "有 \(duplicated.count) 条事件被重复登记在同一个位置",
                evidence: Array(Set(duplicated)).sorted().prefix(5).joined(separator: "、"),
                suggestion: "删掉多出来的那条，否则造上下文包时同一件事会被灌两遍。"))
        }
    }

    // MARK: C. 伏笔台账自身的烂账（埋点修复的核心）

    @MainActor
    private static func auditClueLedger(store: ProjectStore, corpus: ChapterCorpus,
                                        asOf: Int, report: inout ContinuityReport) {
        let clues = store.clues
        guard !clues.isEmpty else { return }
        let horizon = max(asOf, store.project.targetChapters)
        let clueByID = Dictionary(clues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allChapterNumbers = Set(store.chapters.map(\.number))
        let lastChapterNumber = store.chapters.map(\.number).max() ?? 0

        // 骨架触点按伏笔归组：一次遍历，供「疑似已兑现」与「触点矛盾」复用
        var touchesByClue: [String: [(chapter: Int, action: ClueActionKind, requirement: String)]] = [:]
        var orphanTouches: [(chapter: Int, clueID: String, action: ClueActionKind, requirement: String)] = []
        for num in corpus.numbers {
            guard let touches = corpus.chapter(num)?.skeleton?.clueTouches else { continue }
            for t in touches {
                if clueByID[t.clueID] != nil {
                    touchesByClue[t.clueID, default: []].append((chapter: num, action: t.action, requirement: t.requirement))
                } else {
                    orphanTouches.append((chapter: num, clueID: t.clueID, action: t.action, requirement: t.requirement))
                }
            }
        }

        var quoteIssues = 0, targetIssues = 0, paceIssues = 0
        var silentIssues = 0, ghostIssues = 0, futureIssues = 0, noLogIssues = 0, emptyIssues = 0
        var targetReported = Set<String>()   // 逾期已经报过的，不再叠一条节奏过期
        var silentReported = Set<String>()

        for clue in clues.sorted(by: { $0.id < $1.id }) {
            let label = clueLabel(clue)
            let isOpen = clue.status == .planted || clue.status == .developing
            let ledgerText = firstNonEmpty([clue.plantedQuote, clue.detail, clue.title])

            // 15. 台账说埋在某章，那一章却没有正文
            let plantText = corpus.text(clue.plantedChapter)
            if clue.plantedChapter > 0, plantText.isEmpty, emptyIssues < 8 {
                let exists = corpus.chapter(clue.plantedChapter) != nil
                emptyIssues += 1
                report.issues.append(ValidationIssue(
                    severity: .note, category: "伏笔台账",
                    message: "\(label)说埋在第\(clue.plantedChapter)章，\(exists ? "可那一章还是空的" : "可书架上根本没有这一章")",
                    evidence: "台账：\(clip(ledgerText, 80))",
                    suggestion: exists ? "把埋设段补进第\(clue.plantedChapter)章，或把埋设章改成真正埋了的那一章。"
                                       : "把埋设章改成一个真实存在的章号，否则回灌上下文时会指向空气。"))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .replant,
                    chapter: exists ? clue.plantedChapter : max(1, asOf),
                    reason: "台账说这条线埋在第\(clue.plantedChapter)章，\(exists ? "但那一章没有正文" : "但那一章不存在")，读者根本看不到。",
                    action: exists
                        ? "在第\(clue.plantedChapter)章补一段能被指认的埋设：一个具体物件、一个动作或一句台词，不要只写心里犯嘀咕。"
                        : "在第\(max(1, asOf))章补一段能被指认的埋设，并把台账的埋设章改成这一章。",
                    newStatus: ClueStatus.planted.rawValue,
                    evidence: clip(ledgerText, 100)))
            }

            // 8. 种下原文与正文对不上
            let quote = clue.plantedQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            if fold(quote).count >= 6, !plantText.isEmpty, quoteIssues < 8 {
                let located = locate(quote: quote, in: plantText, folded: corpus.folded(clue.plantedChapter),
                                     sentences: corpus.sentences(clue.plantedChapter))
                if located.score < quoteFoundSimilarity {
                    quoteIssues += 1
                    let hopeless = located.score < quoteHopeless
                    report.issues.append(ValidationIssue(
                        severity: .warning, category: "伏笔台账",
                        message: hopeless
                            ? "\(label)的种下原文在第\(clue.plantedChapter)章正文里找不到了"
                            : "\(label)的种下原文和第\(clue.plantedChapter)章正文对不上了（最像的一段也只有 \(percent(located.score))）",
                        evidence: hopeless
                            ? "台账存的是：\(clip(quote, 100))"
                            : "台账存的是：\(clip(quote, 60))\n正文里最接近的是：\(clip(located.fragment, 60))",
                        suggestion: hopeless
                            ? "要么把这段埋设补回正文，要么把台账的种下原文换成正文里真实存在的句子。"
                            : "把种下原文换成正文里真实存在的那一段，将来兑现时才能拿它跟读者对账。"))
                    report.clueFixes.append(ClueFix(
                        clueID: clue.id, kind: .requote, chapter: clue.plantedChapter,
                        reason: "台账存的种下原文已经和第\(clue.plantedChapter)章正文不符——多半是改稿时把那段重写或删掉了。",
                        action: hopeless
                            ? "去第\(clue.plantedChapter)章挑一句真正承担埋设的话贴回来；挑不出来就走「补埋」。"
                            : "把种下原文替换成第\(clue.plantedChapter)章里现存的这一段。",
                        newQuote: hopeless ? nil : clip(located.fragment, 120),
                        evidence: hopeless ? clip(quote, 100) : "台账：\(clip(quote, 60))\n正文：\(clip(located.fragment, 60))"))
                    if hopeless {
                        report.clueFixes.append(ClueFix(
                            clueID: clue.id, kind: .replant, chapter: max(1, clue.plantedChapter),
                            reason: "第\(clue.plantedChapter)章正文里完全没有这条线的影子，等于这条伏笔从没埋下过。",
                            action: "在第\(clue.plantedChapter)章补一段能被指认的埋设（具体物件/动作/台词），补完把种下原文一并更新。",
                            newStatus: ClueStatus.planted.rawValue,
                            evidence: clip(ledgerText, 100)))
                    }
                }
            }

            // 9. 兑现逾期：目标章已过，线还挂着
            if let target = clue.targetPayoffChapter, target < asOf, isOpen, targetIssues < 8 {
                targetIssues += 1
                targetReported.insert(clue.id)
                let relaxed = relaxedTiming(clue.timing)
                let suggested = max(asOf + 2, min(horizon, asOf + max(2, clue.timing.overdueAfterChapters / 2)))
                report.issues.append(ValidationIssue(
                    severity: .warning, category: "伏笔台账",
                    message: "\(label)本该在第\(target)章兑现，现在写到第\(asOf)章还没收（逾期 \(asOf - target) 章）",
                    evidence: clip(ledgerText, 100),
                    suggestion: "近几章就收掉、把兑现章顺延、或显式搁置——三选一，别让它烂在账上。"))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .retarget, chapter: suggested,
                    reason: "原定第\(target)章兑现，已经逾期 \(asOf - target) 章，台账还挂着「\(clue.status.rawValue)」。",
                    action: "把兑现章顺延到第\(suggested)章，节奏放宽到「\(relaxed.rawValue)」。",
                    newTimingRaw: relaxed.rawValue, newTargetChapter: suggested,
                    evidence: clip(ledgerText, 100)))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .defer, chapter: asOf,
                    reason: "这条线暂时不收，但一直挂着会天天报逾期。",
                    action: "标记为已搁置，停止逾期告警；哪天想收了再改回推进中。",
                    newStatus: ClueStatus.deferred.rawValue,
                    evidence: clip(ledgerText, 100)))
            }

            // 10. 节奏过期：太久没动，读者已经忘了
            if isOpen, !targetReported.contains(clue.id), paceIssues < 8,
               clue.isOverdue(currentChapter: asOf), asOf > clue.lastActionChapter {
                paceIssues += 1
                let idle = asOf - clue.lastActionChapter
                report.issues.append(ValidationIssue(
                    severity: .warning, category: "伏笔台账",
                    message: "\(label)已经 \(idle) 章没动静了（它的节奏是「\(clue.timing.rawValue)」，超过 \(clue.timing.overdueAfterChapters) 章读者就忘了）",
                    evidence: clip(ledgerText, 100),
                    suggestion: "近章推进一次、显式搁置、或干脆放弃。"))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .defer, chapter: asOf,
                    reason: "这条线 \(idle) 章没推进，按「\(clue.timing.rawValue)」的节奏已经过期。",
                    action: "标记为已搁置，先把它从催办清单里拿掉。",
                    newStatus: ClueStatus.deferred.rawValue,
                    evidence: clip(ledgerText, 100)))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .abandon, chapter: asOf,
                    reason: "如果这条线已经不打算收了，挂着只会一直报警，也会污染上下文包。",
                    action: "标记为已放弃，台账留档但不再催办。",
                    newStatus: ClueStatus.abandoned.rawValue,
                    evidence: clip(ledgerText, 100)))
            }

            // 11A. 疑似已兑现未记账：骨架在后面某章点了揭示/回收，台账却还挂着
            if isOpen, silentIssues < 8, let paid = touchesByClue[clue.id]?
                .first(where: { $0.chapter > clue.plantedChapter && ($0.action == .reveal || $0.action == .resolve) }) {
                silentIssues += 1
                silentReported.insert(clue.id)
                report.issues.append(ValidationIssue(
                    severity: .note, category: "伏笔台账",
                    message: "\(label)在第\(paid.chapter)章的骨架里已经\(paid.action.rawValue)过了，台账还写着「\(clue.status.rawValue)」",
                    evidence: "第\(paid.chapter)章骨架要求：\(clip(firstNonEmpty([paid.requirement, ledgerText]), 80))",
                    suggestion: "确认一下是不是已经收了；收了就把台账标成已回收，免得它继续占着催办清单。"))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .resolve, chapter: paid.chapter,
                    reason: "第\(paid.chapter)章的骨架已经安排\(paid.action.rawValue)这条线，台账却没记。",
                    action: "把状态改成已回收，并补一条第\(paid.chapter)章的\(paid.action.rawValue)日志。",
                    newStatus: ClueStatus.resolved.rawValue,
                    evidence: clip(firstNonEmpty([paid.requirement, ledgerText]), 100)))
            }

            // 12. 动作日志指向不存在的章
            // 超出全书范围的章号归「未来动作」管，不在这里重复报一遍
            let ghosts = clue.actions.filter {
                $0.chapter <= 0 || (!allChapterNumbers.contains($0.chapter) && $0.chapter <= lastChapterNumber)
            }
            if !ghosts.isEmpty, ghostIssues < 8 {
                ghostIssues += 1
                let nums = ghosts.map(\.chapter).sorted()
                report.issues.append(ValidationIssue(
                    severity: .note, category: "伏笔台账",
                    message: "\(label)的动作日志记在了不存在的章上（第\(nums.prefix(4).map { String($0) }.joined(separator: "、"))章）",
                    evidence: ghosts.prefix(3).map { "第\($0.chapter)章「\($0.kind.rawValue)」\(clip($0.note, 40))" }.joined(separator: "；"),
                    suggestion: "把章号改对，或删掉这几条日志——否则复盘和回灌都会指向空气。"))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .replant, chapter: max(1, asOf),
                    reason: "这条线的轨迹记在书架上没有的章上，等于断了线。",
                    action: "先把日志章号改对；改不出来的，就在第\(max(1, asOf))章补一段能被指认的埋设把线接回正文。",
                    newStatus: ClueStatus.planted.rawValue,
                    evidence: clip(ledgerText, 100)))
            }

            // 13. 未来动作：台账跑到了写作进度前面
            let futureLogs = clue.actions.filter { $0.chapter > asOf }
            if futureIssues < 8, clue.lastActionChapter > asOf || !futureLogs.isEmpty {
                futureIssues += 1
                let far = max(clue.lastActionChapter, futureLogs.map(\.chapter).max() ?? 0)
                let retargeted = max(asOf + 2, min(horizon, asOf + clue.timing.overdueAfterChapters))
                report.issues.append(ValidationIssue(
                    severity: .warning, category: "伏笔台账",
                    message: "\(label)记了第\(far)章的动作，可现在才写到第\(asOf)章",
                    evidence: futureLogs.isEmpty
                        ? "台账最后动作章：第\(clue.lastActionChapter)章"
                        : futureLogs.prefix(3).map { "第\($0.chapter)章「\($0.kind.rawValue)」\(clip($0.note, 30))" }.joined(separator: "；"),
                    suggestion: "把章号改回真实进度。台账超前会让逾期、过期、催办的判断全部失真。"))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .retarget, chapter: asOf,
                    reason: "台账记的动作发生在还没写的第\(far)章，进度对不上。",
                    action: "把最后动作章拉回第\(asOf)章，兑现目标重排到第\(retargeted)章；写错的日志章号顺手改掉。",
                    newTargetChapter: retargeted,
                    evidence: clip(ledgerText, 100)))
            }

            // 14. 已回收却没有回收日志
            if clue.status == .resolved, noLogIssues < 8,
               !clue.actions.contains(where: { $0.kind == .resolve || $0.kind == .reveal }) {
                noLogIssues += 1
                let guess = clue.lastActionChapter > 0 ? clue.lastActionChapter : asOf
                report.issues.append(ValidationIssue(
                    severity: .note, category: "伏笔台账",
                    message: "\(label)标成已回收，却查不到是哪一章、怎么收的",
                    evidence: firstNonEmpty([clue.plantedQuote, clue.detail]).isEmpty
                        ? "台账状态：已回收；动作日志 \(clue.actions.count) 条，没有回收记录"
                        : clip(firstNonEmpty([clue.plantedQuote, clue.detail]), 100),
                    suggestion: "补一条回收日志（第几章、怎么收的），以后复盘和回灌才有据可查。"))
                report.clueFixes.append(ClueFix(
                    clueID: clue.id, kind: .resolve, chapter: guess,
                    reason: "台账写着已回收，但没有一条回收/揭示日志，说不清是在哪儿收的。",
                    action: "在第\(guess)章补记一条回收日志，写清楚是怎么兑现的。",
                    newStatus: ClueStatus.resolved.rawValue,
                    evidence: clip(ledgerText, 100)))
            }
        }

        // 11B. 正文与台账高度相似却没记账（章在外、伏笔在内，避免逐条伏笔全文扫描）
        let openClues = clues.filter {
            ($0.status == .planted || $0.status == .developing) && !silentReported.contains($0.id)
        }
        if !openClues.isEmpty, silentIssues < 8 {
            let keyed: [(clue: Clue, tokens: Set<String>, threshold: Int)] = openClues.map { c in
                let tokens = bigrams(c.title).union(bigrams(c.plantedQuote))
                return (c, tokens, max(2, tokens.count / 3))
            }
            var done = silentReported
            for num in corpus.numbers {
                guard silentIssues < 8 else { break }
                let text = corpus.text(num)
                guard !text.isEmpty else { continue }
                let chapterGrams = bigrams(text)
                // 章级预筛：整章都没有这条线的字面痕迹就直接跳过，句子级比对只在少数章上做
                let candidates = keyed.filter { item in
                    item.clue.plantedChapter < num && !done.contains(item.clue.id)
                        && overlap(item.tokens, chapterGrams) >= item.threshold
                }
                guard !candidates.isEmpty else { continue }
                for sentence in corpus.sentences(num) where fold(sentence).count >= 8 {
                    let sentenceGrams = bigrams(sentence)
                    for item in candidates where overlap(item.tokens, sentenceGrams) >= 2 {
                        let clue = item.clue
                        let score = max(similarity(clue.title, sentence), similarity(clue.plantedQuote, sentence))
                        guard score >= resolvedSimilarity else { continue }
                        silentIssues += 1
                        done.insert(clue.id)
                        report.issues.append(ValidationIssue(
                            severity: .note, category: "伏笔台账",
                            message: "\(clueLabel(clue))看着已经在第\(num)章兑现了，台账还写着「\(clue.status.rawValue)」",
                            evidence: clip(sentence, 100),
                            suggestion: "对一下是不是同一件事；是的话把台账标成已回收，别让它继续占着催办清单。"))
                        report.clueFixes.append(ClueFix(
                            clueID: clue.id, kind: .resolve, chapter: num,
                            reason: "第\(num)章正文和这条线高度重合（\(percent(score))），大概率已经收掉了。",
                            action: "确认后置为已回收，并补一条第\(num)章的回收日志。",
                            newStatus: ClueStatus.resolved.rawValue,
                            evidence: clip(sentence, 120)))
                        break
                    }
                    guard silentIssues < 8 else { break }
                }
            }
        }

        // 16. 骨架触点矛盾
        var touchIssues = 0
        for num in corpus.numbers {
            guard touchIssues < 8, let touches = corpus.chapter(num)?.skeleton?.clueTouches else { continue }
            for t in touches {
                guard touchIssues < 8, let clue = clueByID[t.clueID] else { continue }
                if t.action == .plant, clue.plantedChapter > 0, clue.plantedChapter < num {
                    touchIssues += 1
                    report.issues.append(ValidationIssue(
                        severity: .warning, category: "骨架触点",
                        message: "第\(num)章的骨架要把\(clueLabel(clue))再埋一次，可它第\(clue.plantedChapter)章就埋过了",
                        evidence: firstNonEmpty([t.requirement, clue.plantedQuote, clue.detail]).isEmpty
                            ? "第\(num)章骨架：埋设 \(clue.id)"
                            : clip(firstNonEmpty([t.requirement, clue.plantedQuote, clue.detail]), 100),
                        suggestion: "改成「推进」或「揭示」；同一条线埋两次，读者会觉得作者在原地打转。"))
                } else if t.action == .reveal || t.action == .resolve {
                    let alreadyAt = clue.actions
                        .filter { ($0.kind == .reveal || $0.kind == .resolve) && $0.chapter < num }
                        .map(\.chapter).min()
                    // 台账状态是「已回收」就已经足够判定矛盾——不能因为作者当初没补回收日志
                    // 就放过「收了又要再收一次」。缺日志是另一条检查（#14）在管，两件事各报各的。
                    if clue.status == .resolved {
                        touchIssues += 1
                        let whereClosed = alreadyAt.map { "第\($0)章" } ?? "台账里"
                        report.issues.append(ValidationIssue(
                            severity: .warning, category: "骨架触点",
                            message: "第\(num)章的骨架又要\(t.action.rawValue)\(clueLabel(clue))，但它\(whereClosed)就已经收掉了",
                            evidence: firstNonEmpty([t.requirement, clue.plantedQuote]).isEmpty
                                ? "第\(num)章骨架：\(t.action.rawValue) \(clue.id)；台账状态已回收"
                                : clip(firstNonEmpty([t.requirement, clue.plantedQuote]), 100),
                            suggestion: "把这条触点从骨架里去掉，或换成别的还没收的线；台账若记错了就先修台账。"))
                    }
                }
            }
        }
        // 孤儿引用：骨架点了台账里没有的编号 → 顺手给出补登记
        for orphan in orphanTouches.prefix(8) {
            touchIssues += 1
            let wanted = firstNonEmpty([orphan.requirement])
            report.issues.append(ValidationIssue(
                severity: .warning, category: "骨架触点",
                message: "第\(orphan.chapter)章的骨架点了「\(orphan.clueID)」这条线，台账里查无此项",
                evidence: wanted.isEmpty ? "第\(orphan.chapter)章骨架：\(orphan.action.rawValue) \(orphan.clueID)" : clip(wanted, 100),
                suggestion: "在台账里补建这条伏笔，或把骨架里的编号改成已有的那一条。"))
            report.clueFixes.append(ClueFix(
                clueID: "", kind: .register, chapter: orphan.chapter,
                reason: "骨架已经在用「\(orphan.clueID)」这个编号，台账却没有这条线，合同对不上账。",
                action: "按骨架的要求补建一条伏笔，埋设章记为第\(orphan.chapter)章。",
                newStatus: ClueStatus.planted.rawValue,
                newTitle: wanted.isEmpty ? orphan.clueID : clip(wanted, 20),
                newDetail: "由第\(orphan.chapter)章骨架的\(orphan.action.rawValue)触点补登记（原编号 \(orphan.clueID)）：\(clip(wanted, 80))",
                evidence: clip(wanted, 120)))
        }

        // 17. 正文反复出现、台账与事实库都没登记的专名（保守：最多 5 条）
        auditUnregisteredNouns(store: store, corpus: corpus, asOf: asOf, report: &report)
    }

    /// 反复出现却没登记的专名 → 可能是漏记的伏笔
    @MainActor
    private static func auditUnregisteredNouns(store: ProjectStore, corpus: ChapterCorpus,
                                               asOf: Int, report: inout ContinuityReport) {
        guard corpus.numbers.count >= 3 else { return }
        // 已登记过的名字：伏笔台账 + 事实库 + 别名表（人物已经在册，不算漏埋的伏笔）
        let registered = (store.clues.flatMap { [$0.title, $0.detail, $0.plantedQuote] }
            + store.facts.flatMap { [$0.subject, $0.object] }
            + store.characterAliases.flatMap { [$0.canonicalName] + $0.aliases }
            + store.storylines.map(\.name))
            .map { fold($0) }
            .joined(separator: "｜")

        var nounCache: [Int: [String]] = [:]
        var chaptersSeen: [String: [Int]] = [:]
        for num in corpus.numbers {
            let text = corpus.text(num)
            guard !text.isEmpty else { continue }
            let nouns = nounCache[num] ?? properNouns(String(text.prefix(nounScanCap)), limit: 20)
            nounCache[num] = nouns
            for w in nouns { chaptersSeen[w, default: []].append(num) }
        }

        let ranked = chaptersSeen
            .filter { $0.value.count >= 3 && !registered.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                if lhs.key.count != rhs.key.count { return lhs.key.count > rhs.key.count }
                return lhs.key < rhs.key
            }
            .prefix(60)
        // 同一个专名的不同切片只报一次（青铜 / 铜门 / 青铜门 是一件事，不是三条伏笔）
        var candidates: [(noun: String, chapters: [Int])] = []
        for (noun, chapters) in ranked {
            if candidates.contains(where: { $0.noun.contains(noun) || noun.contains($0.noun) }) { continue }
            candidates.append((noun: noun, chapters: chapters))
            if candidates.count >= 5 { break }
        }

        for (noun, chapters) in candidates {
            let listed = chapters.prefix(6).map { String($0) }.joined(separator: "、")
            let firstChapter = chapters[0]
            let ev = corpus.sentences(firstChapter).first { $0.contains(noun) } ?? ""
            guard !ev.isEmpty else { continue }
            report.issues.append(ValidationIssue(
                severity: .note, category: "伏笔台账",
                message: "「\(noun)」在 \(chapters.count) 章里反复出现（第\(listed)\(chapters.count > 6 ? "章等" : "章")），台账和事实库都没登记",
                evidence: clip(ev, 100),
                suggestion: "如果它是有意埋的线，就补登一条伏笔；如果只是背景名词，可以忽略这条提醒。"))
            report.clueFixes.append(ClueFix(
                clueID: "", kind: .register, chapter: firstChapter,
                reason: "「\(noun)」从第\(firstChapter)章起在 \(chapters.count) 章里反复出现，却没有任何台账记录。",
                action: "补登一条伏笔，埋设章记为第\(firstChapter)章，种下原文用下面这段。",
                newStatus: ClueStatus.planted.rawValue,
                newQuote: clip(ev, 120),
                newTitle: noun,
                newDetail: "由全书审查自动发现：第\(listed)\(chapters.count > 6 ? "章等" : "章")反复出现「\(noun)」，作者确认是否为有意埋设。",
                evidence: clip(ev, 120)))
        }
    }

    // MARK: D. 结构完整性

    @MainActor
    private static func auditStructure(store: ProjectStore, corpus: ChapterCorpus,
                                       asOf: Int, report: inout ContinuityReport) {
        // 18. 章号断裂
        let unique = Array(Set(store.chapters.map(\.number))).sorted()
        var gaps: [String] = []
        var previous = unique.first
        for num in unique.dropFirst() {
            if let p = previous, num - p > 1 {
                gaps.append(num - p == 2 ? "第\(p + 1)章" : "第\(p + 1)–\(num - 1)章")
            }
            previous = num
        }
        let duplicatedCount = store.chapters.count - unique.count
        if !gaps.isEmpty || duplicatedCount > 0 {
            var detail = gaps.prefix(5).joined(separator: "、")
            if duplicatedCount > 0 {
                detail += detail.isEmpty ? "有 \(duplicatedCount) 章章号重复" : "；另有 \(duplicatedCount) 章章号重复"
            }
            report.issues.append(ValidationIssue(
                severity: .note, category: "结构",
                message: "章号不连续：缺 \(gaps.isEmpty ? 0 : gaps.count) 段\(duplicatedCount > 0 ? "，且存在重号" : "")",
                evidence: detail,
                suggestion: "章号断档会让「上一章/下一章」的上下文造包取错章，导出目录也会跳号；重号会让后写的那章存不进磁盘。"))
        }

        // 19. 摘要缺失影响取证（只列前 5 章，不逐章刷屏）
        let missing = store.chapters
            .filter { $0.number <= asOf && $0.summary == nil && $0.wordCount > 500 }
            .map(\.number).sorted()
        if !missing.isEmpty {
            report.issues.append(ValidationIssue(
                severity: .note, category: "结构",
                message: "\(missing.count) 章写了正文却没有摘要（第\(missing.prefix(5).map { String($0) }.joined(separator: "、"))\(missing.count > 5 ? "章等" : "章")）",
                evidence: missing.prefix(5).map { n in
                    let words = store.chapter(n)?.wordCount ?? 0
                    return "第\(n)章 \(words) 字"
                }.joined(separator: "；"),
                suggestion: "没有摘要，后面造上下文包只能塞正文原文，既贵又容易超限；写完全书审查也更难取证。"))
        }

        // 20. 有意留白的设定被正文写死了
        let openSections = store.canonSections.filter { $0.certainty == .open }
        guard !openSections.isEmpty else { return }
        var pending: [(section: String, noun: String)] = []
        var seenNouns = Set<String>()
        for section in openSections {
            // 长切片优先：正文里能对上的通常是最完整的那个专名
            for noun in properNouns(section.title, limit: 5).sorted(by: { $0.count > $1.count })
            where !seenNouns.contains(noun) {
                seenNouns.insert(noun)
                pending.append((section: section.title, noun: noun))
            }
        }
        guard !pending.isEmpty else { return }

        var reported = 0
        var reportedSections = Set<String>()
        for num in corpus.numbers {
            guard reported < 5, !pending.isEmpty else { break }
            let text = corpus.text(num)
            guard !text.isEmpty else { continue }
            let sentences = corpus.sentences(num)
            var still: [(section: String, noun: String)] = []
            for item in pending {
                // 一份设定只报一次：命中它最长的那个专名就够了，别把切片各报一遍
                guard !reportedSections.contains(item.section) else { continue }
                guard let ev = sentences.first(where: { $0.contains(item.noun) }) else {
                    still.append(item)
                    continue
                }
                reportedSections.insert(item.section)
                reported += 1
                report.issues.append(ValidationIssue(
                    severity: .note, category: "结构",
                    message: "设定「\(item.section)」你标的是有意留白，但第\(num)章正文已经把「\(item.noun)」写出来了",
                    evidence: clip(ev, 100),
                    suggestion: "确认一下：如果这就是你想要的定论，把那份设定的确定度从「有意留白」改成「已定」；如果不想写死，把正文这段改虚。"))
                if reported >= 5 { break }
            }
            pending = still
        }
    }

    // MARK: - 纯函数（可单测）

    /// 中文双字组（bigram）Jaccard 相似度：空串返回 0，完全相同返回 1。
    /// 比对前先折叠掉标点与空白——台账里的原文常常跨行、标点被改过。
    static func similarity(_ a: String, _ b: String) -> Double {
        let ba = bigrams(a)
        let bb = bigrams(b)
        guard !ba.isEmpty, !bb.isEmpty else {
            // 不足两个字的退化情形：靠字面相等兜住「完全相同返回 1」这条契约
            return (a == b && !a.isEmpty) ? 1 : 0
        }
        return jaccard(ba, bb)
    }

    /// 从中文里抽人名/专名候选（2-4 字连续 CJK 片段，过滤停用词）
    static func properNouns(_ text: String, limit: Int = 20) -> [String] {
        guard limit > 0, !text.isEmpty else { return [] }
        var freq: [String: Int] = [:]
        for range in text.regexMatches(of: cjkRunPattern) {
            let chars = Array(text[range])
            guard chars.count >= 2 else { continue }
            for len in 2...min(4, chars.count) {
                for i in 0...(chars.count - len) {
                    let candidate = String(chars[i..<(i + len)])
                    guard !isNoise(candidate) else { continue }
                    freq[candidate, default: 0] += 1
                }
            }
        }
        guard !freq.isEmpty else { return [] }
        // 长文里专名一定会复现；短标题（设定文档名）本来就只出现一次，不能按复现次数卡死
        let minFreq = fold(text).count >= 120 ? 2 : 1
        let ranked = freq.filter { $0.value >= minFreq }
            .sorted { ($0.value, $0.key.count) > ($1.value, $1.key.count) }
            .prefix(400)
        var picked: [(String, Int)] = []
        for (candidate, f) in ranked {
            // 「紫渊真人」反复出现时，同频的「紫渊真」「紫渊」是冗余切片。
            // 只在频次有意义（长文）时做这层去冗：短标题里最长的切片反而最不可能原样出现在正文里。
            if minFreq >= 2,
               picked.contains(where: { $0.1 >= f && $0.0.count > candidate.count && $0.0.contains(candidate) }) { continue }
            picked.append((candidate, f))
        }
        return picked
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                // 同频时取更长的切片：「青铜门」比「青铜」「铜门」更接近真正的专名
                if lhs.0.count != rhs.0.count { return lhs.0.count > rhs.0.count }
                return lhs.0 < rhs.0
            }
            .prefix(limit)
            .map { $0.0 }
    }

    // MARK: - 内部工具

    fileprivate static let cjkRunPattern = "[\\u4E00-\\u9FFF\\u3400-\\u4DBF]{2,}"

    /// 位移线索。单字动词只保留指向明确的那几个——「去/回/出/入」几乎每章都有，
    /// 用它们会把这项检查彻底噎死。
    fileprivate static let movementVerbs: [String] = [
        "走", "跑", "飞", "赶", "奔", "逃", "乘", "驾", "渡", "挪", "启程", "跋涉",
        "离开", "抵达", "赶到", "赶往", "赶回", "返回", "折返", "撤退", "出发", "动身",
        "上路", "来到", "回到", "回去", "回来", "前去", "前往", "去了", "去往", "踏入",
        "走进", "走出", "传送", "穿越", "降落", "潜入", "登上", "下了车", "上马", "登船",
    ]

    /// 回忆/追述标记：命中就不算「死者复出」（宁可漏报，不误伤闪回）
    fileprivate static let flashbackMarkers: [String] = [
        "生前", "回忆", "想起", "记得", "当年", "曾经", "从前", "往日", "旧日", "昔日",
        "那年", "小时候", "幼时", "往事", "追忆", "梦见", "梦里", "梦中", "脑海", "记忆里",
        "墓", "坟", "棺", "尸", "遗物", "遗言", "遗书", "灵位", "牌位", "骨灰", "祭",
    ]

    /// 专名抽取的整词停用表（叙事元词 + 高频虚词组合）
    fileprivate static let stopwordPhrases: Set<String> = [
        "世界", "世界观", "人物", "势力", "设定", "修炼", "体系", "修炼体系", "时间", "时间线",
        "大纲", "章节", "故事", "情节", "伏笔", "线索", "主角", "配角", "反派", "地理", "历史",
        "背景", "简介", "备注", "说明", "目录", "附录", "番外", "序章", "尾声", "作者", "读者",
        "身世", "来历", "秘密", "真相", "身份", "结局", "悬念", "力量", "等级", "境界", "门派",
        "我们", "你们", "他们", "她们", "它们", "自己", "什么", "怎么", "这样", "那样", "一个",
        "没有", "不是", "可以", "因为", "所以", "但是", "如果", "虽然", "然后", "现在", "已经",
        "还是", "只是", "就是", "于是", "可是", "或者", "以及", "对于", "关于", "通过", "进行",
        "开始", "结束", "出现", "发生", "存在", "成为", "作为", "时候", "地方", "东西", "事情",
        "问题", "感觉", "知道", "觉得", "看到", "听见", "起来", "出来", "进来", "过去", "下来",
        "一声", "一眼", "一步", "一起", "一直", "一定", "一点", "有些", "忽然", "突然", "顿时",
        "瞬间", "片刻", "这时候", "那时候", "不知道", "为什么", "怎么样", "不可能", "没有人",
        "第一", "第二", "第三", "最后", "接下来", "与此同时", "另一方面",
    ]

    /// 首尾虚词：任何以这些字开头/结尾的片段都不像专名
    fileprivate static let edgeNoise: Set<Character> = [
        "的", "了", "是", "在", "和", "与", "就", "都", "而", "及", "也", "很", "更", "最",
        "那", "我", "你", "他", "她", "它", "们", "个", "些", "着", "过", "把", "被", "让",
        "使", "吗", "呢", "啊", "吧", "呀", "哦", "嗯", "并", "或", "但", "若", "虽", "因",
        "所", "以", "于", "之", "其", "此", "该", "还", "再", "又", "才", "只", "便", "却",
        "将", "已", "未", "非", "每", "各", "某", "另", "别", "得", "地", "么", "样", "们",
    ]

    /// 只留汉字与字母数字：标点、空白、markdown 记号一律折掉，比对才不会被格式差异带偏
    fileprivate static func isContentScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)      // CJK 基本区
            || (0x3400...0x4DBF).contains(v)      // 扩展 A
            || (0x30...0x39).contains(v)          // 数字
            || (0x41...0x5A).contains(v)          // 大写字母
            || (0x61...0x7A).contains(v)          // 小写字母
    }

    fileprivate static func contentScalars(_ s: String) -> [Unicode.Scalar] {
        s.unicodeScalars.filter { isContentScalar($0) }
    }

    fileprivate static func fold(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars where isContentScalar(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    fileprivate static func bigrams(_ s: String) -> Set<String> {
        let scalars = contentScalars(s)
        guard scalars.count >= 2 else { return [] }
        var out = Set<String>()
        out.reserveCapacity(scalars.count)
        for i in 0..<(scalars.count - 1) {
            var pair = String()
            pair.unicodeScalars.append(scalars[i])
            pair.unicodeScalars.append(scalars[i + 1])
            out.insert(pair)
        }
        return out
    }

    fileprivate static func jaccard(_ x: Set<String>, _ y: Set<String>) -> Double {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let (small, large) = x.count <= y.count ? (x, y) : (y, x)
        var inter = 0
        for g in small where large.contains(g) { inter += 1 }
        let union = x.count + y.count - inter
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// a 里有多少元素落在 b 中（不对称，用作便宜的预筛）
    fileprivate static func overlap(_ a: Set<String>, _ b: Set<String>) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var n = 0
        for g in a where b.contains(g) { n += 1 }
        return n
    }

    fileprivate static func isNoise(_ s: String) -> Bool {
        if stopwordPhrases.contains(s) { return true }
        guard let first = s.first, let last = s.last else { return true }
        return edgeNoise.contains(first) || edgeNoise.contains(last)
    }

    /// 台账里存的种下原文能否在正文里定位到：先整段精确、再连续 6 字片段、最后模糊滑窗
    fileprivate static func locate(quote: String, in text: String, folded: String,
                                   sentences: [String]) -> (score: Double, fragment: String) {
        let q = fold(quote)
        guard q.count >= 4, !text.isEmpty else { return (0, "") }
        if folded.contains(q) { return (1, quote.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let qChars = Array(q)
        if qChars.count >= 6 {
            // 改稿常只动几个字：只要有连续 6 字还在，就认为埋设仍然存在
            for i in 0...(qChars.count - 6) where folded.contains(String(qChars[i..<(i + 6)])) {
                return (0.9, quote.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let target = bigrams(quote)
        var best = (score: 0.0, fragment: "")

        // 句子级：能给出作者可直接粘回台账的自然片段
        for s in sentences {
            let len = fold(s).count
            guard len >= 6, len <= qChars.count * 4 + 20 else { continue }
            let score = jaccard(target, bigrams(s))
            if score > best.score { best = (score: score, fragment: s) }
        }

        // 滑窗级：埋设被并进长句时，句子级会漏
        let textChars = Array(text)
        let window = max(8, min(qChars.count, textChars.count))
        if textChars.count >= window {
            let stride = max(4, window / 4)
            var k = 0
            while k + window <= textChars.count {
                let piece = String(textChars[k..<(k + window)])
                let score = jaccard(target, bigrams(piece))
                if score > best.score { best = (score: score, fragment: piece) }
                k += stride
            }
        }
        return best
    }

    /// 死者复出的取证句：命中名字、且不是回忆/追述/见尸
    fileprivate static func firstRevivalSentence(in sentences: [String], names: [String]) -> String? {
        for s in sentences {
            guard names.contains(where: { s.contains($0) }) else { continue }
            if flashbackMarkers.contains(where: { s.contains($0) }) { continue }
            return s
        }
        return nil
    }

    fileprivate static func names(for subject: String, aliases: [CharacterAlias]) -> [String] {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out = [trimmed]
        for entry in aliases {
            let canonical = entry.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            let all = [canonical] + entry.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard all.contains(trimmed) else { continue }
            for name in all where !name.isEmpty && !out.contains(name) { out.append(name) }
        }
        // 单字名太容易误伤（「渊」会命中所有带渊的句子），一律不采信
        return out.filter { fold($0).count >= 2 }
    }

    fileprivate static func relaxedTiming(_ t: ClueTiming) -> ClueTiming {
        switch t {
        case .immediate: return .nearTerm
        case .nearTerm: return .midArc
        case .midArc: return .slowBurn
        case .slowBurn: return .endgame
        case .endgame: return .endgame
        }
    }

    fileprivate static func clueLabel(_ clue: Clue) -> String {
        let title = clue.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "伏笔 \(clue.id) " : "「\(title)」（\(clue.id)）"
    }

    fileprivate static func eventLabel(_ e: TimelineEvent) -> String {
        e.id.isEmpty ? "" : "事件「\(e.id)」"
    }

    fileprivate static func eventEvidence(_ e: TimelineEvent, fallback: String) -> String {
        clip(firstNonEmpty([e.objectiveFact, e.readerKnowledge, e.notes, fallback]), 100)
    }

    fileprivate static func firstNonEmpty(_ values: [String]) -> String {
        for v in values {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return ""
    }

    fileprivate static func clip(_ s: String, _ n: Int = 60) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > n else { return t }
        return String(t.prefix(n)) + "…"
    }

    fileprivate static func percent(_ d: Double) -> String {
        "\(Int((d * 100).rounded()))%"
    }
}

// MARK: - 正文语料

/// 一次审查只建一份：正文按需截断、句子按需切分并缓存，避免在循环里反复扫全文
private final class ChapterCorpus {
    let numbers: [Int]
    private let byNumber: [Int: Chapter]
    private var textCache: [Int: String] = [:]
    private var foldedCache: [Int: String] = [:]
    private var sentenceCache: [Int: [String]] = [:]
    private var movementCache: [Int: Bool] = [:]

    init(chapters: [Chapter], through: Int) {
        var seen = Set<Int>()
        var scoped: [Chapter] = []
        for c in chapters.sorted(by: { $0.number < $1.number }) where c.number <= through {
            guard seen.insert(c.number).inserted else { continue }   // 重号只取第一条
            scoped.append(c)
        }
        numbers = scoped.map(\.number)
        byNumber = Dictionary(scoped.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func chapter(_ n: Int) -> Chapter? { byNumber[n] }

    func text(_ n: Int) -> String {
        if let cached = textCache[n] { return cached }
        let t = byNumber[n].map { String($0.prose.prefix(ContinuityAuditor.proseCap)) } ?? ""
        textCache[n] = t
        return t
    }

    /// 折掉标点/空白的正文（种下原文常跨行、标点被改过）
    func folded(_ n: Int) -> String {
        if let cached = foldedCache[n] { return cached }
        let t = ContinuityAuditor.fold(text(n))
        foldedCache[n] = t
        return t
    }

    func sentences(_ n: Int) -> [String] {
        if let cached = sentenceCache[n] { return cached }
        let s = text(n).splitSentence()
        sentenceCache[n] = s
        return s
    }

    func hasMovement(_ n: Int, verbs: [String]) -> Bool {
        if let cached = movementCache[n] { return cached }
        let text = self.text(n)
        let hit = !text.isEmpty && verbs.contains { text.contains($0) }
        movementCache[n] = hit
        return hit
    }
}
