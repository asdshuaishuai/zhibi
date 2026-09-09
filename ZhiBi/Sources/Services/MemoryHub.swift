import Foundation

// MARK: - 记忆中枢（Agent 记忆模组）
// 验收回笼：AI 提取 → 作者验收 → 入库 → 这里做统一整理（去重/矛盾体检/人物归一）
// → 下次写作时由 ContextPackBuilder 统一回灌给 agent，形成记忆闭环。
// 整理全部是确定性代码（账房归我们），并生成可读的报告。

enum MemoryHub {
    struct Conflict: Identifiable {
        var id: String { "\(subject)|\(predicate)" }
        var subject: String
        var predicate: String
        /// 冲突的多值（按章节升序）
        var values: [(object: String, chapter: Int, factIDs: [UUID])]
    }

    struct ConsolidationReport {
        var removedDuplicates = 0
        var renamedByAlias = 0
        var conflictsFound = 0
        var details: [String] = []

        var isEmpty: Bool { details.isEmpty }

        var summary: String {
            var lines: [String] = []
            if removedDuplicates > 0 { lines.append("清除完全重复事实 \(removedDuplicates) 条") }
            if renamedByAlias > 0 { lines.append("按别名归一主语 \(renamedByAlias) 处") }
            if conflictsFound > 0 { lines.append("发现待裁决矛盾 \(conflictsFound) 组（见矛盾体检）") }
            if lines.isEmpty { lines.append("账本很干净，无需整理。") }
            return lines.joined(separator: "；")
        }
    }

    // MARK: 完全重复（三元组 + 起始章都一致）

    static func deduplicate(_ facts: [MemoryFact]) -> (kept: [MemoryFact], removed: Int) {
        var seen = Set<String>()
        var kept: [MemoryFact] = []
        var removed = 0
        for f in facts {
            let key = "\(f.subject)|\(f.predicate)|\(f.object)|\(f.fromChapter)"
            if seen.contains(key) {
                removed += 1
            } else {
                seen.insert(key)
                kept.append(f)
            }
        }
        return (kept, removed)
    }

    // MARK: 矛盾体检：同主语同谓词、对象不同、同时有效（读者可见层面）

    static func conflicts(_ facts: [MemoryFact]) -> [Conflict] {
        let valid = facts.filter { $0.isValid(atChapter: 9999) }
        var groups: [String: [MemoryFact]] = [:]
        for f in valid where f.predicate != "知道" && f.predicate != "相信" && f.predicate != "目标" {
            groups["\(f.subject)|\(f.predicate)", default: []].append(f)
        }
        var result: [Conflict] = []
        for (key, group) in groups {
            let distinct = Dictionary(grouping: group, by: \.object).map { ($0.key, $0.value) }
            guard distinct.count > 1 else { continue }
            let parts = key.split(separator: "|")
            let values = distinct
                .map { (object: $0.0, chapter: $0.1.map(\.fromChapter).min() ?? 0, factIDs: $0.1.map(\.id)) }
                .sorted { $0.chapter < $1.chapter }
            result.append(Conflict(subject: parts.count > 0 ? String(parts[0]) : "",
                                   predicate: parts.count > 1 ? String(parts[1]) : "",
                                   values: values))
        }
        return result.sorted { $0.subject < $1.subject }
    }

    // MARK: 人物归一：别名表里 alias → canonical，重写主语

    static func unifySubjects(_ facts: [MemoryFact], aliases: [CharacterAlias]) -> (facts: [MemoryFact], renamed: Int) {
        let map = Dictionary(aliases.flatMap { a in a.aliases.map { ($0, a.canonicalName) } },
                             uniquingKeysWith: { first, _ in first })
        var renamed = 0
        let out = facts.map { f -> MemoryFact in
            if let canonical = map[f.subject], canonical != f.subject {
                var nf = f
                nf.subject = canonical
                renamed += 1
                return nf
            }
            return f
        }
        return (out, renamed)
    }

    // MARK: 一键整理（确定性）

    static func consolidate(facts: [MemoryFact], aliases: [CharacterAlias]) -> (facts: [MemoryFact], report: ConsolidationReport) {
        var report = ConsolidationReport()
        let unified = unifySubjects(facts, aliases: aliases)
        report.renamedByAlias = unified.renamed
        let deduped = deduplicate(unified.facts)
        report.removedDuplicates = deduped.removed
        report.conflictsFound = conflicts(deduped.kept).count
        report.details.append(report.summary)
        return (deduped.kept, report)
    }

    // MARK: 回笼统计：账本规模与使用情况（给"记忆统一"页顶栏）

    struct LedgerStats {
        var totalFacts = 0
        var activeFacts = 0
        var invalidated = 0
        var hiddenFromReader = 0
        var authoredCount = 0
        var subjects = 0
        var summaries = 0

        /// 记忆健康度 0-100：有效事实占比 + 有摘要的章比例（粗略）
        var health: Int {
            guard totalFacts > 0 else { return 100 }
            let validRatio = Double(activeFacts) / Double(totalFacts)
            return Int((validRatio * 80 + (summaries > 0 ? 20 : 0)).rounded())
        }
    }

    @MainActor
    static func ledgerStats(store: ProjectStore) -> LedgerStats {
        let chapters = store.chapters.filter { $0.summary != nil }.count
        return LedgerStats(
            totalFacts: store.facts.count,
            activeFacts: store.facts.filter { $0.isValid(atChapter: 9999) }.count,
            invalidated: store.facts.filter { !$0.isValid(atChapter: 9999) }.count,
            hiddenFromReader: store.facts.filter { !$0.publicToReader && $0.isValid(atChapter: 9999) }.count,
            authoredCount: store.facts.filter { $0.source == "authored" }.count,
            subjects: Set(store.facts.map(\.subject)).count,
            summaries: chapters)
    }
}
