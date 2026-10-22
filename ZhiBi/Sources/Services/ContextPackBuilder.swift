import Foundation

// MARK: - 确定性上下文造包（NarraCat WritingContextPack 同构）
// 纯代码组装、分区块 token 预算硬截断；热/温/贯穿线三层 + 伏笔 due-list。

struct ContextBlock: Identifiable {
    var id: String { title }
    var title: String
    var content: String
    var protected: Bool   // 受保护层：预算紧张时最后才动（inkos protected/compressible）
    /// 块级优先级：数字越小越先保留（同 protected 时按此排序裁剪）
    var priority: Int = 50
}

struct ContextPack {
    var blocks: [ContextBlock] = []
    var approxTokens: Int { blocks.reduce(0) { $0 + WordStats.approxTokens($1.content) } }
    /// 预算裁剪记录（超预算时填充，UI/日志可展示「压掉了什么」）
    var trimmedNotes: [String] = []

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

        func add(_ title: String, _ content: String, protected: Bool = true, cap: Int = 1500, priority: Int = 50) {
            let trimmed = String(content.prefix(cap))
            guard !trimmed.isEmpty else { return }
            pack.blocks.append(ContextBlock(title: title, content: trimmed, protected: protected, priority: priority))
        }

        // 控制面（人的接口，最高优先）
        add("作者意图", project.authorIntent, cap: 800, priority: 10)
        add("当前焦点", project.currentFocus, cap: 500, priority: 10)
        add("文风要求（作者主权）", project.styleNotes, cap: 800, priority: 10)

        // 热层：上一章逐字结尾 + 近 3 章摘要
        if let prev = store.chapter(n - 1), !prev.prose.isEmpty {
            let ending = String(prev.prose.suffix(500))
            add("上一章结尾（逐字，开头必须接住这里的情绪）", ending, cap: 600, priority: 20)
        }
        let recent = store.chapters.filter { $0.number < n && $0.summary != nil }.suffix(3)
        for ch in recent {
            var s = "《\(ch.title)》\(ch.summary!.summary)"
            if !ch.summary!.keyEvents.isEmpty {
                s += "\n关键事件：" + ch.summary!.keyEvents.joined(separator: "；")
            }
            add("第\(ch.number)章摘要", s, protected: false, cap: 700, priority: 20)
        }

        // 贯穿线常驻层（永不丢弃）
        let through = store.storylines.filter { $0.isThroughLine || $0.kind == .main }
        if !through.isEmpty {
            add("贯穿线（常驻）", through.map { "[\($0.id)] \($0.name)：\($0.notes)" }.joined(separator: "\n"), cap: 600, priority: 30)
        }

        // 活跃伏笔 due-list（≤8 条，过期优先）
        let active = store.activeClues(currentChapter: n).prefix(8)
        if !active.isEmpty {
            let lines = active.map { c in
                let overdue = c.isOverdue(currentChapter: n) ? "⚠️已过期" : ""
                return "[\(c.id)] \(c.title)（\(c.status.rawValue)｜\(c.timing.rawValue)）\(overdue)：\(c.detail)" +
                       (c.plantedQuote.isEmpty ? "" : "｜种下原文：\(String(c.plantedQuote.prefix(60)))")
            }
            add("活跃伏笔（本章需要考虑的账）", lines.joined(separator: "\n"), cap: 1400, priority: 30)
        }

        // 长程记忆召回：从全书档案卡里检索与本章相关的历史细节（写到 80 章也能找回
        // 第 12 章的具体物料/台词）——这是"长期记忆"真正生效的通道
        let recall = DossierRecall.recall(store: store, forChapter: n, limit: 5)
        if !recall.dossiers.isEmpty {
            add("历史档案召回（跨全书检索到的相关细节）", recall.asBlock, protected: false, cap: 1600, priority: 30)
        }

        // 角色状态折叠（截至 n-1 章有效的公开事实，按主体折叠）
        var bySubject: [String: [MemoryFact]] = [:]
        for f in store.facts where f.isValid(atChapter: n - 1) && f.publicToReader
            && !f.subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !f.object.trimmingCharacters(in: .whitespaces).isEmpty {
            bySubject[f.subject, default: []].append(f)
        }
        let stateLines = bySubject.sorted { $0.value.count > $1.value.count }.prefix(8).map { subject, fs -> String in
            let latest = fs.sorted { $0.fromChapter < $1.fromChapter }.suffix(4)
            return "\(subject)：" + latest.map { "\($0.predicate)\($0.object)（第\($0.fromChapter)章起）" }.joined(separator: "；")
        }
        add("角色当前状态（读者视角）", stateLines.joined(separator: "\n"), protected: false, cap: 900, priority: 30)

        // 时间线锚点：本章已排的事件 + 最近 5 条
        let related = store.timelineEvents.filter { $0.chapter <= n }.suffix(5)
        if !related.isEmpty {
            add("时间线锚点", related.map { "[\($0.id)] 第\($0.chapter)章：\($0.objectiveFact)" }.joined(separator: "\n"), protected: false, cap: 700, priority: 40)
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
            add("本章骨架（作者已批准的写前契约）", s, cap: 1200, priority: 10)
        }

        // 设定速览
        let canonDigest = store.canonSections.prefix(6).map { "《\($0.title)》：\(String($0.content.prefix(150)))" }
        add("设定速览", canonDigest.joined(separator: "\n"), protected: false, cap: 900, priority: 50)

        // ============ 预算裁剪（budget 参数真正生效的入口）============
        // 策略：按 (protected 优先，priority 小者优先) 依次保留；超预算时
        // ① 低优先级块先按比例压到剩余额度；② 压不下则整块丢弃（记录在 trimmedNotes）。
        // protected 块最后才动（压到 ≥30% 保底，仍不下再丢）。
        pack = ContextPackBuilder.applyBudget(pack, budget: budget)
        return pack
    }

    /// 预算裁剪：把定稿块按 token 预算取舍。budget ≤ 0 视为不限制。
    static func applyBudget(_ pack: ContextPack, budget: Int) -> ContextPack {
        guard budget > 0 else { return pack }
        let total = pack.approxTokens
        guard total > budget else { return pack }

        var out = ContextPack()
        // 保留顺序：protected 先、priority 升序
        let ordered = pack.blocks.sorted { lhs, rhs in
            if lhs.protected != rhs.protected { return lhs.protected }
            return lhs.priority < rhs.priority
        }
        var used = 0
        for block in ordered {
            let cost = WordStats.approxTokens(block.content)
            let remaining = budget - used
            if cost <= remaining {
                out.blocks.append(block)
                used += cost
                continue
            }
            // 放不下：尝试压缩到剩余额度（protected 保底 30% 自身）
            let floor = block.protected ? max(120, cost * 3 / 10) : 0
            let allowed = max(remaining, floor)
            if allowed >= 120 {
                let keepChars = max(80, allowed * 2 / 3)   // token→字符的逆估计
                var trimmed = block
                trimmed.content = String(block.content.prefix(keepChars)) + "…（按上下文预算截断）"
                out.blocks.append(trimmed)
                used += WordStats.approxTokens(trimmed.content)
                out.trimmedNotes.append("「\(block.title)」压缩至 \(keepChars) 字")
            } else {
                out.trimmedNotes.append("「\(block.title)」因预算不足被省略")
            }
        }
        // 恢复原始块序（保留原叙事顺序，便于模型阅读）
        let order = Dictionary(uniqueKeysWithValues: pack.blocks.map { ($0.id, $0.priority) })
        out.blocks.sort { (order[$0.id] ?? 50) < (order[$1.id] ?? 50) }
        return out
    }

    /// 供 PromptLibrary 使用：按模型上下文预算计算「单段正文」可注入上限。
    /// 预算的 55% 留给正文（其余给骨架/账本/法典/输出），至少 4000 字防太小。
    static func proseInjectionCap(budget: Int, hardCap: Int) -> Int {
        guard budget > 0 else { return hardCap }
        let tokenBudget = budget * 55 / 100
        let chars = tokenBudget * 2 / 3
        return max(4000, min(hardCap, chars))
    }
}
