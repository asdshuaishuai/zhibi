import Foundation

// MARK: - 确定性上下文造包（NarraCat WritingContextPack 同构）
// 纯代码组装、分区块 token 预算硬截断；热/温/贯穿线三层 + 伏笔 due-list。

struct ContextBlock: Identifiable {
    var id: String { title }
    var title: String
    var content: String
    var protected: Bool   // 受保护层：永不压缩丢弃（inkos protected/compressible）
}

struct ContextPack {
    var blocks: [ContextBlock] = []
    var approxTokens: Int { blocks.reduce(0) { $0 + WordStats.approxTokens($1.content) } }

    var asText: String {
        blocks.map { "【\($0.title)】\n\($0.content)" }.joined(separator: "\n\n")
    }
}

enum ContextPackBuilder {
    /// 为"写第 N 章"组装上下文包
    @MainActor
    static func build(store: ProjectStore, forChapter n: Int, budget: Int) -> ContextPack {
        var pack = ContextPack()
        let project = store.project

        func add(_ title: String, _ content: String, protected: Bool = true, cap: Int = 1500) {
            let trimmed = String(content.prefix(cap))
            guard !trimmed.isEmpty else { return }
            pack.blocks.append(ContextBlock(title: title, content: trimmed, protected: protected))
        }

        // 控制面（人的接口，最高优先）
        add("作者意图", project.authorIntent, cap: 800)
        add("当前焦点", project.currentFocus, cap: 500)
        add("文风要求（作者主权）", project.styleNotes, cap: 800)

        // 热层：上一章逐字结尾 + 近 3 章摘要
        if let prev = store.chapter(n - 1), !prev.prose.isEmpty {
            let ending = String(prev.prose.suffix(500))
            add("上一章结尾（逐字，开头必须接住这里的情绪）", ending, cap: 600)
        }
        let recent = store.chapters.filter { $0.number < n && $0.summary != nil }.suffix(3)
        for ch in recent {
            var s = "《\(ch.title)》\(ch.summary!.summary)"
            if !ch.summary!.keyEvents.isEmpty {
                s += "\n关键事件：" + ch.summary!.keyEvents.joined(separator: "；")
            }
            add("第\(ch.number)章摘要", s, protected: false, cap: 700)
        }

        // 贯穿线常驻层（永不丢弃）
        let through = store.storylines.filter { $0.isThroughLine || $0.kind == .main }
        if !through.isEmpty {
            add("贯穿线（常驻）", through.map { "[\($0.id)] \($0.name)：\($0.notes)" }.joined(separator: "\n"), cap: 600)
        }

        // 活跃伏笔 due-list（≤8 条，过期优先）
        let active = store.activeClues(currentChapter: n).prefix(8)
        if !active.isEmpty {
            let lines = active.map { c in
                let overdue = c.isOverdue(currentChapter: n) ? "⚠️已过期" : ""
                return "[\(c.id)] \(c.title)（\(c.status.rawValue)｜\(c.timing.rawValue)）\(overdue)：\(c.detail)" +
                       (c.plantedQuote.isEmpty ? "" : "｜种下原文：\(String(c.plantedQuote.prefix(60)))")
            }
            add("活跃伏笔（本章需要考虑的账）", lines.joined(separator: "\n"), cap: 1400)
        }

        // 角色状态折叠（截至 n-1 章有效的公开事实，按主体折叠）
        var bySubject: [String: [MemoryFact]] = [:]
        for f in store.facts where f.isValid(atChapter: n - 1) && f.publicToReader {
            bySubject[f.subject, default: []].append(f)
        }
        let stateLines = bySubject.sorted { $0.value.count > $1.value.count }.prefix(8).map { subject, fs -> String in
            let latest = fs.sorted { $0.fromChapter < $1.fromChapter }.suffix(4)
            return "\(subject)：" + latest.map { "\($0.predicate)\($0.object)（第\($0.fromChapter)章起）" }.joined(separator: "；")
        }
        add("角色当前状态（读者视角）", stateLines.joined(separator: "\n"), protected: false, cap: 900)

        // 时间线锚点：本章已排的事件 + 最近 5 条
        let related = store.timelineEvents.filter { $0.chapter <= n }.suffix(5)
        if !related.isEmpty {
            add("时间线锚点", related.map { "[\($0.id)] 第\($0.chapter)章：\($0.objectiveFact)" }.joined(separator: "\n"), protected: false, cap: 700)
        }

        // 骨架（若已定）
        if let sk = store.chapter(n)?.skeleton, !sk.beats.isEmpty {
            let lines = sk.beats.enumerated().map { i, b in
                "\(i + 1). \(b.summary)（\(b.purpose)\(b.suggestedWords > 0 ? "｜约\(b.suggestedWords)字" : "")）"
            }
            var s = lines.joined(separator: "\n")
            if !sk.endHook.isEmpty { s += "\n章尾钩子：\(sk.endHook)" }
            if !sk.mustDeliver.isEmpty { s += "\n硬交付：" + sk.mustDeliver.joined(separator: "；") }
            if !sk.mustAvoid.isEmpty { s += "\n禁止：" + sk.mustAvoid.joined(separator: "；") }
            add("本章骨架（作者已批准的写前契约）", s, cap: 1200)
        }

        // 设定速览
        let canonDigest = store.canonSections.prefix(6).map { "《\($0.title)》：\(String($0.content.prefix(150)))" }
        add("设定速览", canonDigest.joined(separator: "\n"), protected: false, cap: 900)

        return pack
    }
}
