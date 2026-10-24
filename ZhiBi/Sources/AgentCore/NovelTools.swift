import Foundation

/// 宿主提供的工具面。铁律：
/// 1. 只存在 propose_*（提案）与只读查询工具——**不存在任何绕过提案直接写正文的工具**；
/// 2. 会改书的工具执行 = 创建提案进收件箱，回复模型"等待作者确认"；只读查询直接返回证据，
///    模型口头声明不算采纳。
enum NovelTools {
    private static let timingMap = ["immediate": ClueTiming.immediate, "near_term": ClueTiming.nearTerm, "mid_arc": ClueTiming.midArc, "slow_burn": ClueTiming.slowBurn, "endgame": ClueTiming.endgame]
    private static let scaleMap = ["small": ClueScale.small, "medium": ClueScale.medium, "major": ClueScale.major]

    static func all(store: ProjectStore, chapter: Int = 0, config: AgentConfig? = nil) -> [AgentTool] {
        [
            proposeOutlineEvents(store: store),
            proposeStorylines(store: store),
            proposeClues(store: store),
            proposeSkeleton(store: store, chapter: chapter),
            proposeDraft(store: store, chapter: chapter),
            proposeMemory(store: store, chapter: chapter),
            proposeValidation(store: store, chapter: chapter),
            proposeContinuity(store: store),
            proposeOutlineUpdates(store: store),
            proposeDeslop(store: store, chapter: chapter),
            proposeMemo(store: store),
            proposeCanon(store: store),
            proposeCanonClassify(store: store),
            proposeDossier(store: store, chapter: chapter),
            getChapter(store: store),
            getClues(store: store),
            getOutline(store: store),
            getCanon(store: store),
            getFacts(store: store),
            getChapterSkeleton(store: store),
            getLatestDraft(store: store),
            searchKnowledge(store: store, config: config),
        ]
    }

    // MARK: - 提案工具

    static func proposeOutlineEvents(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_outline_events",
            description: "提交核心大纲事件时间线提案。事件采用双时间线：objective_fact 是作者真相（客观发生了什么），reader_knowledge 是读者已知（读者此刻被告知了什么）。未揭示的事件 revealed=false。提案进入收件箱等待作者确认，你不得假设已采纳。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string","description":"给作者的一两句说明"},"events":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"chapter":{"type":"integer"},"objective_fact":{"type":"string"},"reader_knowledge":{"type":"string"},"revealed":{"type":"boolean"},"storyline_ids":{"type":"array","items":{"type":"string"}}},"required":["chapter","objective_fact","reader_knowledge"]}}},"required":["events"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct E: Decodable {
                    let id: String?
                    let chapter: Int
                    let objective_fact: String
                    let reader_knowledge: String
                    let revealed: Bool?
                    let storyline_ids: [String]?
                }
                let note: String?
                let events: [E]
            }
            let p = try decode(Payload.self, args)
            // E 编号全局唯一（原按 id|chapter 查重，允许同号跨章 → 台账出现重复 E 号）
            let events: [TimelineEvent] = await MainActor.run {
                var used = Set(store.timelineEvents.map(\.id))
                let validLineIDs = Set(store.storylines.map(\.id))
                var nextNumber = (store.timelineEvents.compactMap { e -> Int? in
                    guard e.id.hasPrefix("E"), let n = Int(e.id.dropFirst()) else { return nil }
                    return n
                }.max() ?? 0) + 1
                var out: [TimelineEvent] = []
                for e in p.events {
                    var id = e.id ?? ""
                    if id.isEmpty || used.contains(id) {
                        repeat {
                            id = String(format: "E%02d", nextNumber)
                            nextNumber += 1
                        } while used.contains(id)
                    }
                    used.insert(id)
                    out.append(TimelineEvent(
                        id: id,
                        chapter: e.chapter,
                        objectiveFact: e.objective_fact,
                        readerKnowledge: e.reader_knowledge,
                        revealed: e.revealed ?? false,
                        // 悬空引用防护：只保留真实存在的故事线 id
                        storylineIDs: (e.storyline_ids ?? []).filter { validLineIDs.contains($0) }
                    ))
                }
                return out
            }
            let proposal = AIProposal(capability: .outlineTimeline, chapterNumber: nil,
                                      title: "事件时间线（\(events.count) 条）",
                                      note: p.note ?? "", payload: .outlineEvents(events))
            await store.addProposal(proposal)
            return "已登记为提案「事件时间线」，等待作者在收件箱确认。不要假设提案已被采纳。"
        }
    }

    static func proposeStorylines(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_storylines",
            description: "提交故事线提案（L 编号）。主线一条，可含成长/感情/势力/悬疑/对手/世界等支线；贯穿全书的主线应设 is_through_line=true。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"storylines":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string","enum":["main","growth","romance","faction","mystery","rivalry","world","other"]},"is_through_line":{"type":"boolean"},"entry_chapter":{"type":"integer"},"planned_payoff_chapter":{"type":"integer"},"notes":{"type":"string"}},"required":["name","kind"]}}},"required":["storylines"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct S: Decodable {
                    let id: String?
                    let name: String
                    let kind: String
                    let is_through_line: Bool?
                    let entry_chapter: Int?
                    let planned_payoff_chapter: Int?
                    let notes: String?
                }
                let note: String?
                let storylines: [S]
            }
            let p = try decode(Payload.self, args)
            let kindMap = ["main": StorylineKind.main, "growth": .growth, "romance": .romance, "faction": .faction,
                           "mystery": .mystery, "rivalry": .rivalry, "world": .world, "other": .other]
            // 编号取「已有最大 L 号 + 1」查重：AI 不传 id 时不能与既有故事线撞号（撞号会被去重静默丢弃）
            let existing = await store.storylines
            let maxLine = existing.compactMap { l -> Int? in
                guard l.id.hasPrefix("L"), let n = Int(l.id.dropFirst()) else { return nil }
                return n
            }.max() ?? 0
            var nextLine = maxLine
            let lines = p.storylines.enumerated().map { _, s -> Storyline in
                var sid = s.id ?? ""
                if sid.isEmpty {
                    nextLine += 1
                    sid = String(format: "L%02d", nextLine)
                }
                return Storyline(id: sid, name: s.name,
                       kind: kindMap[s.kind] ?? .other, isThroughLine: s.is_through_line ?? false,
                       entryChapter: s.entry_chapter, plannedPayoffChapter: s.planned_payoff_chapter,
                       notes: s.notes ?? "")
            }
            await store.addProposal(AIProposal(capability: .outlineTimeline, title: "故事线（\(lines.count) 条）",
                                               note: p.note ?? "", payload: .storylines(lines)))
            return "已登记为提案「故事线」，等待作者确认。"
        }
    }

    static func proposeClues(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_clues",
            description: "提交伏笔/线索提案（F 编号）。scale: small=本弧内/medium=本卷内/major=跨卷；timing: immediate/near_term/mid_arc/slow_burn/endgame。planted_quote 必须摘抄种下伏笔时的原文片段，便于日后兑现时回灌对照。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"clues":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"detail":{"type":"string"},"scale":{"type":"string","enum":["small","medium","major"]},"timing":{"type":"string","enum":["immediate","near_term","mid_arc","slow_burn","endgame"]},"importance":{"type":"string","enum":["高","中","低"]},"planted_chapter":{"type":"integer"},"planted_quote":{"type":"string"},"target_payoff_chapter":{"type":"integer"}},"required":["title","detail","planted_chapter"]}}},"required":["clues"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct C: Decodable {
                    let id: String?
                    let title: String
                    let detail: String
                    let scale: String?
                    let timing: String?
                    let importance: String?
                    let planted_chapter: Int
                    let planted_quote: String?
                    let target_payoff_chapter: Int?
                }
                let note: String?
                let clues: [C]
            }
            let p = try decode(Payload.self, args)
            let clues = await MainActor.run { () -> [Clue] in
                var used = Set(store.clues.map(\.id))
                var nextNumber = (store.clues.compactMap { c -> Int? in
                    guard c.id.hasPrefix("F"), let n = Int(c.id.dropFirst()) else { return nil }
                    return n
                }.max() ?? 0) + 1
                var out: [Clue] = []
                for c in p.clues {
                    var id = c.id ?? ""
                    if id.isEmpty || used.contains(id) {
                        repeat {
                            id = String(format: "F%02d", nextNumber)
                            nextNumber += 1
                        } while used.contains(id)
                    }
                    used.insert(id)
                    out.append(Clue(id: id, title: c.title, detail: c.detail,
                                    scale: scaleMap[c.scale ?? "medium"] ?? .medium,
                                    timing: timingMap[c.timing ?? "mid_arc"] ?? .midArc,
                                    importance: c.importance ?? "中",
                                    plantedChapter: c.planted_chapter,
                                    plantedQuote: c.planted_quote ?? "",
                                    targetPayoffChapter: c.target_payoff_chapter,
                                    status: .planted, lastActionChapter: c.planted_chapter,
                                    actions: [ClueActionLog(chapter: c.planted_chapter, kind: .plant, note: "登记")]))
                }
                return out
            }
            await store.addProposal(AIProposal(capability: .clueLedger, title: "伏笔台账（\(clues.count) 条）",
                                               note: p.note ?? "", payload: .clues(clues)))
            return "已登记为提案「伏笔台账」，等待作者确认。"
        }
    }

    static func proposeSkeleton(store: ProjectStore, chapter: Int) -> AgentTool {
        AgentTool(
            name: "propose_skeleton",
            description: "提交章节骨架提案。你不写正文，只规划这章要完成什么：3-6 个节拍（beats）。每拍除了 summary（要发生什么）与 purpose（功能定位），还要填**场景层**：pov（这一拍贴着谁写）/ location（具体地点）/ time_label（时间标记）/ cast（在场人物，用台账本名）/ turn（这一拍从什么变成什么）——场景层是宿主做连贯性审查的取证基础，缺了就查不出视角漂移与分身两地。另外要给：end_hook 章尾钩子 + hook_kind 钩子形态（悬念/危机/反转/信息差/承诺/情绪/登场，连续多章同型会形成套版感）、must_deliver 硬交付、must_avoid 禁止项（至少一条反 AI 指纹约束）、clue_touches 伏笔触点合同（clue_id + action: plant/develop/reveal/resolve/defer + requirement 硬要求）、payoff_type 本章兑现的爽点类型、new_expectation 本章挂上的可验证新期待、volume_label 所属卷。揭1埋1：每回收一个伏笔就至少埋一个新钩子；到期未动的伏笔必须进合同。宿主会用确定性闸门给这份骨架打分，有阻塞项会退回让你重修。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"beats":{"type":"array","minItems":3,"maxItems":6,"items":{"type":"object","properties":{"summary":{"type":"string"},"purpose":{"type":"string"},"clue_ids":{"type":"array","items":{"type":"string"}},"suggested_words":{"type":"integer"},"pov":{"type":"string","description":"这一拍贴着谁写；全章应统一"},"location":{"type":"string","description":"具体地点"},"time_label":{"type":"string","description":"时间标记，要能和相邻拍对上"},"cast":{"type":"array","items":{"type":"string"},"description":"在场人物，用台账本名"},"turn":{"type":"string","description":"这一拍从什么变成什么"}},"required":["summary"]}},"end_hook":{"type":"string"},"hook_kind":{"type":"string","enum":["悬念","危机","反转","信息差","承诺","情绪","登场"]},"pov":{"type":"string","description":"本章主视角"},"must_deliver":{"type":"array","items":{"type":"string"}},"must_avoid":{"type":"array","items":{"type":"string"}},"clue_touches":{"type":"array","items":{"type":"object","properties":{"clue_id":{"type":"string"},"action":{"type":"string","enum":["plant","develop","reveal","resolve","defer"]},"requirement":{"type":"string"}},"required":["clue_id","action"]}},"payoff_type":{"type":"string","description":"本章兑现的爽点类型"},"new_expectation":{"type":"string","description":"本章挂上的新期待，必须可验证"},"volume_label":{"type":"string","description":"所属卷/阶段"}},"required":["beats","end_hook"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct B: Decodable {
                    let summary: String
                    let purpose: String?
                    let clue_ids: [String]?
                    let suggested_words: Int?
                    let pov: String?
                    let location: String?
                    let time_label: String?
                    let cast: [String]?
                    let turn: String?
                }
                struct T: Decodable {
                    let clue_id: String
                    let action: String
                    let requirement: String?
                }
                let note: String?
                let beats: [B]
                let end_hook: String
                let hook_kind: String?
                let pov: String?
                let must_deliver: [String]?
                let must_avoid: [String]?
                let clue_touches: [T]?
                let payoff_type: String?
                let new_expectation: String?
                let volume_label: String?
            }
            let p = try decode(Payload.self, args)
            let actionMap = ["plant": ClueActionKind.plant, "develop": .develop, "reveal": .reveal,
                             "resolve": ClueActionKind.resolve, "defer": ClueActionKind.defer]
            let sk = ChapterSkeleton(
                beats: p.beats.map { b in
                    Beat(summary: b.summary, purpose: b.purpose ?? "", clueIDs: b.clue_ids ?? [],
                         suggestedWords: b.suggested_words ?? 0,
                         pov: b.pov ?? "", location: b.location ?? "", timeLabel: b.time_label ?? "",
                         cast: b.cast ?? [], turn: b.turn ?? "")
                },
                endHook: p.end_hook,
                mustDeliver: p.must_deliver ?? [],
                mustAvoid: p.must_avoid ?? [],
                clueTouches: (p.clue_touches ?? []).map { t in
                    ClueTouch(clueID: t.clue_id, action: actionMap[t.action] ?? .plant, requirement: t.requirement ?? "")
                },
                proposedByAI: true,
                hookKind: p.hook_kind ?? "",
                pov: p.pov ?? "",
                payoffType: p.payoff_type ?? "",
                newExpectation: p.new_expectation ?? "",
                volumeLabel: p.volume_label ?? ""
            )
            // 宿主闸门：确定性打分 + 问题清单。有阻塞项时直接回给模型，让它在同一轮里自我修正——
            // 这比让作者拿到一份不合格骨架再手动挑错省事得多，也不违反「人裁决」铁律（仍是提案）。
            let gate = await MainActor.run { SkeletonGate.evaluate(sk, store: store, chapter: chapter) }
            await store.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: chapter,
                                               title: "第\(chapter)章 骨架（\(sk.beats.count) 拍·闸门 \(gate.score)/100）",
                                               note: gateNote(p.note ?? "", gate), payload: .skeleton(sk)))
            guard gate.blockers.isEmpty else {
                return """
                已登记提案「章节骨架」，但宿主闸门查出 \(gate.blockers.count) 项阻塞问题（评分 \(gate.score)/100）：
                \(gate.blockers.map { "- \($0.message) → \($0.suggestion)" }.joined(separator: "\n"))
                \(gate.warnings.isEmpty ? "" : "另有建议项：\n" + gate.warnings.prefix(6).map { "- \($0.message) → \($0.suggestion)" }.joined(separator: "\n"))
                请修好后再调用一次 propose_skeleton（会登记为新提案，作者取用哪版由他决定）。
                """
            }
            return "已登记为提案「章节骨架」（闸门 \(gate.score)/100，\(gate.warnings.count) 项建议已附在提案说明里），等待作者在收件箱确认。下一步可生成整章草稿提案；正文由作者审查、修改、采纳后定稿。"
        }
    }

    /// 把闸门结果写进提案说明：作者在收件箱里直接看到该改什么，不用自己对着骨架猜
    private static func gateNote(_ note: String, _ gate: SkeletonGate.Report) -> String {
        var lines: [String] = []
        if !note.isEmpty { lines.append(note) }
        lines.append("【骨架闸门 \(gate.score)/100】\(gate.summary)")
        if !gate.hookKind.isEmpty {
            lines.append("钩子形态：\(gate.hookKind)\(gate.hookConcrete ? "（挂在具体事物上）" : "（偏空泛，建议落到具体物件/动作）")")
        }
        if !gate.dueMissed.isEmpty { lines.append("到期未进合同的伏笔：\(gate.dueMissed.joined(separator: "、"))") }
        lines.append("伏笔收支：埋 \(gate.plantCount) / 推 \(gate.developCount) / 收 \(gate.revealCount)")
        for i in gate.issues.prefix(8) {
            lines.append("· [\(i.severity.rawValue)] \(i.message) → \(i.suggestion)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 全书连贯性审校 + 埋点修复

    static func proposeContinuity(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_continuity",
            description: "提交全书连贯性审校提案。只查宿主确定性代码查不出来的六类：①动机断裂 ②能力与资源前后不一致（含战力/财富通胀失控）③人物性格漂移 ④称谓与身份混乱 ⑤因果链缺口（结果出现了但导致它的环节从未发生）⑥承诺失约。每条必须带 evidence（具体章号 + 原文引用）与 suggestion（怎么修）。不评风格、节奏、文笔——那是作者主权。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"issues":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string","enum":["blocker","warning","note"]},"category":{"type":"string","enum":["动机断裂","能力资源","性格漂移","称谓身份","因果缺口","承诺失约"]},"chapter":{"type":"integer","description":"问题落在第几章"},"message":{"type":"string"},"evidence":{"type":"string"},"suggestion":{"type":"string"}},"required":["severity","category","message"]}}},"required":["issues"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct I: Decodable {
                    let severity: String
                    let category: String
                    let chapter: Int?
                    let message: String
                    let evidence: String?
                    let suggestion: String?
                }
                let note: String?
                let issues: [I]
            }
            let p = try decode(Payload.self, args)
            let sevMap = ["blocker": Severity.blocker, "warning": .warning, "note": .note]
            // MainActor.run 不接受 async 闭包——先取标量，再直接 await
            let asOf = await MainActor.run { store.currentChapter }
            let deterministic = await ContinuityAuditor.auditAsync(store: store, throughChapter: asOf)
            let aiIssues = p.issues.map { i in
                ValidationIssue(severity: sevMap[i.severity] ?? .warning, category: i.category,
                                message: (i.chapter.map { "第\($0)章：" } ?? "") + i.message,
                                evidence: i.evidence ?? "", suggestion: i.suggestion ?? "")
            }
            // 机械性错误由宿主确定性代码兜底，不花 token；AI 结果合并其上
            var report = ValidationReport(chapter: asOf)
            report.deterministicIssues = deterministic.issues
            report.aiIssues = aiIssues
            await store.addProposal(AIProposal(
                capability: .continuityAudit, chapterNumber: asOf,
                title: "全书连贯性审查（截至第\(asOf)章：确定性 \(deterministic.issues.count) 条 + AI \(aiIssues.count) 条）",
                note: (p.note ?? "") + "\n" + deterministic.summary,
                payload: .report(report)))
            // 埋点修复单独成一条提案：每条都是可一键采纳的账本修正
            if !deterministic.clueFixes.isEmpty {
                await store.addProposal(AIProposal(
                    capability: .continuityAudit, chapterNumber: asOf,
                    title: "埋点修复方案（\(deterministic.clueFixes.count) 条，可逐条采纳）",
                    note: "伏笔台账的烂账：种下原文与正文对不上、兑现逾期、疑似已收未记账、动作日志指向不存在的章等。采纳即改台账，不改正文。",
                    payload: .clueFixes(deterministic.clueFixes)))
            }
            return "已登记提案「全书连贯性审查」（AI \(aiIssues.count) 条，宿主确定性 \(deterministic.issues.count) 条），另有 \(deterministic.clueFixes.count) 条埋点修复方案。等待作者裁决。"
        }
    }

    // MARK: - 大纲同步（计划 vs 实际对账 → 活文档）

    static func proposeOutlineUpdates(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_outline_updates",
            description: "提交大纲更新提案，把静态计划同步成随剧情推进的活文档。kind: event_happened=计划事件已在正文发生 / event_moved=事件改期（给 new_chapter）/ event_revealed=读者已知（此前 revealed=false）/ event_dropped=事件取消 / storyline_status=故事线状态调整（new_status: 进行中/蛰伏/已收束）/ stage_adjust=阶段调整。每条必须写 reason（凭什么这么判）与 evidence（命中哪一章的什么内容）。大纲是作者正典，采纳才生效。要新增大纲里没有的事件请改用 propose_outline_events。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"updates":{"type":"array","maxItems":30,"items":{"type":"object","properties":{"kind":{"type":"string","enum":["event_happened","event_moved","event_revealed","event_dropped","storyline_status","stage_adjust"]},"event_id":{"type":"string"},"storyline_id":{"type":"string"},"stage_id":{"type":"integer"},"new_chapter":{"type":"integer"},"new_status":{"type":"string","enum":["进行中","蛰伏","已收束"]},"reason":{"type":"string"},"evidence":{"type":"string"},"confidence":{"type":"number"}},"required":["kind","reason"]}}},"required":["updates"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct U: Decodable {
                    let kind: String
                    let event_id: String?
                    let storyline_id: String?
                    let stage_id: Int?
                    let new_chapter: Int?
                    let new_status: String?
                    let reason: String
                    let evidence: String?
                    let confidence: Double?
                }
                let note: String?
                let updates: [U]
            }
            let p = try decode(Payload.self, args)
            let kindMap: [String: OutlineUpdate.Kind] = [
                "event_happened": .eventHappened, "event_moved": .eventMoved,
                "event_revealed": .eventRevealed, "event_dropped": .eventDropped,
                "storyline_status": .storylineStatus, "stage_adjust": .stageAdjust,
            ]
            let aiUpdates = p.updates.compactMap { u -> OutlineUpdate? in
                guard let kind = kindMap[u.kind] else { return nil }
                return OutlineUpdate(kind: kind, eventID: u.event_id, storylineID: u.storyline_id,
                                     stageID: u.stage_id, newChapter: u.new_chapter,
                                     newStatusRaw: u.new_status, reason: u.reason,
                                     evidence: u.evidence ?? "", confidence: u.confidence ?? 0)
            }
            // 宿主确定性对账结果一并登记：模型可能漏判，作者能对照两边看
            let det = await OutlineSync.syncAsync(store: store)
            let combined = det.suggestedUpdates + aiUpdates
            let note = [p.note ?? "", det.summary].filter { !$0.isEmpty }.joined(separator: "\n")
            await store.addProposal(AIProposal(
                capability: .outlineSync, chapterNumber: det.asOfChapter,
                title: "大纲同步（截至第\(det.asOfChapter)章：\(combined.count) 条更新建议）",
                note: note, payload: .outlineUpdates(combined)))
            return "已登记提案「大纲同步」\(combined.count) 条（宿主确定性对账 \(det.suggestedUpdates.count) 条 + 你补的 \(aiUpdates.count) 条）。作者采纳后才写回大纲。"
        }
    }

    static func proposeMemory(store: ProjectStore, chapter: Int) -> AgentTool {
        AgentTool(
            name: "propose_memory",
            description: "提交本章记忆包提案：章节摘要（200-500字）+ 事实三元组 + 新伏笔候选。结算铁律：只提取正文中明确描写的事件和状态变化，不要推断、预测、脑补。正文只写到角色走到门口，就不能写『角色已进入房间』。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"summary":{"type":"object","properties":{"text":{"type":"string"},"key_events":{"type":"array","items":{"type":"string"}},"emotional_tone":{"type":"string"}},"required":["text"]},"facts":{"type":"array","items":{"type":"object","properties":{"subject":{"type":"string"},"predicate":{"type":"string","enum":["位于","获得","失去","知道","相信","关系","状态","目标","承诺","死亡","身份","其他"]},"object":{"type":"string"},"public_to_reader":{"type":"boolean","description":"读者是否已知；作者账本性质的暗线事实填 false"},"note":{"type":"string"}},"required":["subject","predicate","object"]}},"new_clues":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"detail":{"type":"string"},"scale":{"type":"string","enum":["small","medium","major"]},"timing":{"type":"string","enum":["immediate","near_term","mid_arc","slow_burn","endgame"]},"planted_quote":{"type":"string"}},"required":["title","detail"]}}},"required":["summary","facts"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct Sum: Decodable { let text: String; let key_events: [String]?; let emotional_tone: String? }
                struct F: Decodable { let subject: String; let predicate: String; let object: String; let public_to_reader: Bool?; let note: String? }
                struct NC: Decodable { let title: String; let detail: String; let scale: String?; let timing: String?; let planted_quote: String? }
                let note: String?
                let summary: Sum
                let facts: [F]
                let new_clues: [NC]?
            }
            let p = try decode(Payload.self, args)
            let sum = ChapterSummary(chapter: chapter, summary: p.summary.text,
                                     keyEvents: p.summary.key_events ?? [],
                                     emotionalTone: p.summary.emotional_tone ?? "")
            let facts = p.facts.map { f in
                MemoryFact(subject: f.subject, predicate: f.predicate, object: f.object,
                           fromChapter: chapter, publicToReader: f.public_to_reader ?? true,
                           source: "extracted", note: f.note ?? "")
            }
            let newClues = (p.new_clues ?? []).map { c in
                Clue(id: "", title: c.title, detail: c.detail,
                     scale: scaleMap[c.scale ?? "small"] ?? .small,
                     timing: timingMap[c.timing ?? "mid_arc"] ?? .midArc,
                     plantedChapter: chapter, plantedQuote: c.planted_quote ?? "",
                     status: .planted, lastActionChapter: chapter)
            }
            await store.addProposal(AIProposal(capability: .memoryExtract, chapterNumber: chapter,
                                               title: "第\(chapter)章 记忆包（\(facts.count) 条事实）",
                                               note: p.note ?? "", payload: .memoryPack(facts: facts, summary: sum, newClueCandidates: newClues)))
            return "已登记为提案「记忆包」，等待作者确认后才会入库。"
        }
    }

    static func proposeValidation(store: ProjectStore, chapter: Int) -> AgentTool {
        AgentTool(
            name: "propose_validation",
            description: "提交一致性验证提案。只查五类客观错误（能指出证据、能被验证）：①连续性矛盾 ②设定违背 ③骨架锚点不可识别 ④伏笔合同未兑现 ⑤物理不可能。风格、节奏、文笔好坏一概不评。每条 issue 必须带 evidence（引用原文）与 suggestion。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"issues":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string","enum":["blocker","warning","note"]},"category":{"type":"string","enum":["连续性","设定违背","骨架锚点","伏笔合同","物理不可能"]},"message":{"type":"string"},"evidence":{"type":"string"},"suggestion":{"type":"string"}},"required":["severity","category","message"]}}},"required":["issues"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct I: Decodable { let severity: String; let category: String; let message: String; let evidence: String?; let suggestion: String? }
                let note: String?
                let issues: [I]
            }
            let p = try decode(Payload.self, args)
            let sevMap = ["blocker": Severity.blocker, "warning": .warning, "note": .note]
            let issues = p.issues.map { i in
                ValidationIssue(severity: sevMap[i.severity] ?? .warning, category: i.category,
                                message: i.message, evidence: i.evidence ?? "", suggestion: i.suggestion ?? "")
            }
            var report = await store.draftValidationReport(for: chapter)
            report.aiIssues = issues
            await store.addProposal(AIProposal(capability: .validation, chapterNumber: chapter,
                                               title: "第\(chapter)章 AI 审校（\(issues.count) 条发现）",
                                               note: p.note ?? "", payload: .report(report)))
            return "已登记为提案「AI 审校报告」，等待作者阅读确认。"
        }
    }

    static func proposeDeslop(store: ProjectStore, chapter: Int) -> AgentTool {
        AgentTool(
            name: "propose_deslop",
            description: "提交去AI味修改建议。核心纪律：改最少、只改『怎么说』不改『说什么』；每条建议给出原文片段 original 与替换 replacement；不确定的标 gate 为「需复核」。不新增原文没有的内容。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"grade":{"type":"string","enum":["轻度","中度","重度"]},"suggestions":{"type":"array","items":{"type":"object","properties":{"gate":{"type":"string"},"original":{"type":"string"},"replacement":{"type":"string"},"reason":{"type":"string"}},"required":["original","replacement"]}}},"required":["grade","suggestions"]}
            """
        ) { args in
            struct Payload: Decodable {
                let note: String?
                let grade: String
                struct S: Decodable { let gate: String?; let original: String; let replacement: String; let reason: String? }
                let suggestions: [S]
            }
            let p = try decode(Payload.self, args)
            let suggestions = p.suggestions.map { s in
                DeslopSuggestion(gate: s.gate ?? "", original: s.original, replacement: s.replacement, reason: s.reason ?? "")
            }
            var report = DeslopReport(chapter: chapter, grade: p.grade, suggestions: suggestions)
            // AILint.scan 是纯函数：文本在主线程取，扫描扔后台——全章 10 万字时
            // 这一步原先要卡主线程 ~0.5s（AI 工具链上每调一次卡一次）
            let prose = await MainActor.run { store.chapter(chapter)?.prose ?? "" }
            report.lint = await Task.detached(priority: .utility) { AILint.scan(prose) }.value
            await store.addProposal(AIProposal(capability: .deslop, chapterNumber: chapter,
                                               title: "第\(chapter)章 去AI味建议（\(suggestions.count) 处，\(p.grade)）",
                                               note: p.note ?? "", payload: .deslop(report)))
            return "已登记为提案「去AI味建议」，逐条采纳与否由作者决定。"
        }
    }

    static func proposeDraft(store: ProjectStore, chapter: Int) -> AgentTool {
        AgentTool(
            name: "propose_draft",
            description: "提交整章草稿提案（你写的初稿/修订稿）。全文放入 text，不要分段输出到对话里。这是提案：作者审查、修改、给意见、采纳之后才会进入正文。每次修订都提交完整全文（不是补丁）。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string","description":"给作者的一句话说明本稿改了什么"},"text":{"type":"string","description":"整章正文全文"}},"required":["text"]}
            """
        ) { args in
            struct Payload: Decodable { let note: String?; let text: String }
            let p = try decode(Payload.self, args)
            let version = await MainActor.run { store.nextDraftVersion(for: chapter) }
            let draft = ChapterDraft(chapter: chapter, text: p.text, version: version,
                                     mainline: "")
            let words = WordStats.chineseCount(p.text)
            await store.addProposal(AIProposal(
                capability: version == 1 ? .chapterDraft : .chapterRevise,
                chapterNumber: chapter,
                title: "第\(chapter)章 草稿 v\(version)（\(words) 字）",
                note: p.note ?? "", payload: .draft(draft)))
            return "已登记草稿提案 v\(version)（\(words) 字），等待作者审查。作者可能给修改意见要求出 v\(version + 1)；在作者采纳前草稿不会进入正文。"
        }
    }

    static func proposeMemo(store: ProjectStore, capability: AICapability = .recallMemo) -> AgentTool {
        AgentTool(
            name: "propose_memo",
            description: "提交写作备忘提案（召回后给作者的写作提醒，2-3 条以内，人话）。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"text":{"type":"string"}},"required":["text"]}
            """
        ) { args in
            struct Payload: Decodable { let note: String?; let text: String }
            let p = try decode(Payload.self, args)
            await store.addProposal(AIProposal(capability: capability, title: "写作备忘", note: p.note ?? "", payload: .memo(p.text)))
            return "已登记为提案「写作备忘」。"
        }
    }

    static func proposeDossier(store: ProjectStore, chapter: Int) -> AgentTool {
        AgentTool(
            name: "propose_dossier",
            description: "提交本章长程记忆档案卡（场景/人物/推进/拐点/悬念/关键物件与台词）。这是跨全书检索的记忆锚点：relics 里放带专名的物料与原句，写到后面的章节要靠它召回本章细节。",
            parametersJSON: """
            {"type":"object","properties":{"headline":{"type":"string"},"scenes":{"type":"array","items":{"type":"string"}},"cast":{"type":"array","items":{"type":"string"}},"advances":{"type":"array","items":{"type":"string"}},"turns":{"type":"array","items":{"type":"string"}},"hooks":{"type":"array","items":{"type":"string"}},"relics":{"type":"array","items":{"type":"string"}}},"required":["headline"]}
            """
        ) { args in
            struct P: Decodable {
                let headline: String
                let scenes: [String]?
                let cast: [String]?
                let advances: [String]?
                let turns: [String]?
                let hooks: [String]?
                let relics: [String]?
            }
            let p = try decode(P.self, args)
            // 检索价值护栏：relics 是长程召回的金矿，空 relics = 这张卡召不回任何细节
            guard let relics = p.relics, !relics.isEmpty else {
                throw AgentError.badResponse("档案卡必须带 relics（关键细节）：至少 3 条带专名的物件/地名/原句台词。请重新提取。")
            }
            var card = ChapterDossier(chapter: chapter, headline: p.headline)
            card.scenes = p.scenes ?? []
            card.cast = p.cast ?? []
            card.advances = p.advances ?? []
            card.turns = p.turns ?? []
            card.hooks = p.hooks ?? []
            card.relics = p.relics ?? []
            await store.addProposal(AIProposal(
                capability: .dossierExtract, chapterNumber: chapter,
                title: "第\(chapter)章 档案卡（长程记忆）",
                note: "采纳后进入跨全书检索记忆库——后续章节写作时自动召回相关历史细节。",
                payload: .dossier(card)))
            return "已登记档案卡提案，等待作者确认。"
        }
    }

    static func proposeCanonClassify(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_canon_classify",
            description: "提交设定归类提案：对宿主列出的每篇设定文档给出分类（世界观/势力人物/修炼体系/剧情大纲/题材规则/未分类）与可选改名。按现有标题精确匹配；改名撞名会被跳过。",
            parametersJSON: """
            {"type": "object", "properties": {"note": {"type": "string"}, "classifications": {"type": "array", "items": {"type": "object", "properties": {"title": {"type": "string", "description": "现有文档标题，逐字一致"}, "category": {"type": "string", "enum": ["世界观", "势力人物", "修炼体系", "剧情大纲", "题材规则", "未分类"]}, "rename": {"type": "string", "description": "可选：规范化后的新标题（加序号前缀如「01·」）"}, "note": {"type": "string"}}, "required": ["title", "category"]}}}, "required": ["classifications"]}
            """
        ) { args in
            struct C: Decodable { let title: String; let category: String; let rename: String?; let note: String? }
            struct P: Decodable { let note: String?; let classifications: [C] }
            let p = try decode(P.self, args)
            let items = p.classifications.map {
                CanonClassItem(title: $0.title, category: $0.category, rename: $0.rename, note: $0.note)
            }
            await store.addProposal(AIProposal(
                capability: .canonClassify,
                title: "设定归类（\(items.count) 篇）",
                note: p.note ?? "采纳后设定页按类别分组展示。",
                payload: .canonClassify(items)))
            return "已登记归类提案 \(items.count) 条，等待作者审阅。"
        }
    }

    static func proposeCanon(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_canon",
            description: "提交设定文档提案（背景框架：世界观 / 势力人物 / 修炼体系 / 题材规则等）。设定是作者主权：你只提案，作者审阅采纳后才写入设定库。每篇文档是 Markdown，可以含表格；每篇聚焦一个主题，合计不超过 6 篇。",
            parametersJSON: """
            {"type":"object","properties":{"docs":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"content":{"type":"string"},"certainty":{"type":"string","enum":["canon","tentative","blank"],"description":"canon=已定正典 tentative=暂定 blank=有意留白"}},"required":["title","content"]}}},"required":["docs"]}
            """
        ) { args in
            struct D: Decodable { let title: String; let content: String; let certainty: String? }
            struct P: Decodable { let docs: [D] }
            let p = try decode(P.self, args)
            let docs = p.docs.map { CanonDocProposal(title: $0.title, content: $0.content, certainty: $0.certainty ?? "tentative") }
            await store.addProposal(AIProposal(
                capability: .framework,
                title: "背景设定框架（\(docs.count) 篇）",
                note: "设定主权在你：采纳后写入设定库，同题不会覆盖你手改过的文档。",
                payload: .canon(docs)))
            return "已登记设定提案 \(docs.count) 篇，等待作者审阅。"
        }
    }

    // MARK: - 只读查询工具

    static func getChapter(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "get_chapter",
            description: "读取某章正文原文。用于验证、对话与检索时对照取证。",
            parametersJSON: """
            {"type":"object","properties":{"chapter":{"type":"integer"}},"required":["chapter"]}
            """
        ) { args in
            struct P: Decodable { let chapter: Int }
            let p = try decode(P.self, args)
            let text = await MainActor.run { store.chapter(p.chapter)?.prose ?? "" }
            return text.isEmpty ? "第\(p.chapter)章还没有正文。" : String(text.prefix(12000))
        }
    }

    /// 读取任意章的骨架（含场景层、钩子、硬交付、伏笔触点与批准状态）。
    /// 对话默认只带当前章骨架；问其他章或对照骨架查草稿时，用这个工具取证。
    static func getChapterSkeleton(store: ProjectStore, chapter: Int? = nil) -> AgentTool {
        AgentTool(
            name: "get_chapter_skeleton",
            description: "读取某章骨架：节拍（含视角/地点/时间/在场/转折）、章尾钩子、硬交付、禁止项、伏笔触点与作者批准状态。chapter 省略则取当前写作章。对照草稿是否漏拍/偏移时先用它。",
            parametersJSON: """
            {"type":"object","properties":{"chapter":{"type":"integer","description":"章号；省略取当前写作章"}}}
            """
        ) { args in
            struct P: Decodable { let chapter: Int? }
            let p = try decode(P.self, args)
            return await MainActor.run {
                let n = p.chapter ?? chapter ?? store.currentChapter
                return chapterSkeletonDescription(store: store, chapter: n)
            }
        }
    }

    /// 供工具与自检共用的同步实现（纯读，不改账本）
    @MainActor
    static func chapterSkeletonDescription(store: ProjectStore, chapter n: Int) -> String {
        guard let sk = store.chapter(n)?.skeleton, !sk.beats.isEmpty else {
            return "第\(n)章还没有骨架。可以先让 AI 搭骨架提案，作者批准后再对照检查。"
        }
        var lines: [String] = [
            "第\(n)章「\(store.chapter(n)?.title ?? "")」骨架（\(sk.humanApproved ? "作者已批准" : "尚未批准")）"
        ]
        for (i, b) in sk.beats.enumerated() {
            var scene: [String] = []
            if !b.pov.isEmpty { scene.append("视角：\(b.pov)") }
            if !b.location.isEmpty { scene.append("地点：\(b.location)") }
            if !b.timeLabel.isEmpty { scene.append("时间：\(b.timeLabel)") }
            if !b.cast.isEmpty { scene.append("在场：\(b.cast.joined(separator: "、"))") }
            if !b.turn.isEmpty { scene.append("转折：\(b.turn)") }
            var line = "\(i + 1). \(b.summary)（\(b.purpose)"
            if b.suggestedWords > 0 { line += "｜约\(b.suggestedWords)字" }
            line += "）"
            if !scene.isEmpty { line += "\n   " + scene.joined(separator: "｜") }
            lines.append(line)
        }
        if !sk.endHook.isEmpty { lines.append("章尾钩子：\(sk.endHook)" + (sk.hookKind.isEmpty ? "" : "（\(sk.hookKind)型）")) }
        if !sk.mustDeliver.isEmpty { lines.append("硬交付：" + sk.mustDeliver.joined(separator: "；")) }
        if !sk.mustAvoid.isEmpty { lines.append("禁止：" + sk.mustAvoid.joined(separator: "；")) }
        if !sk.clueTouches.isEmpty {
            lines.append("伏笔触点：" + sk.clueTouches.map { "[\($0.clueID)] \($0.action.rawValue) —— \($0.requirement)" }.joined(separator: "；"))
        }
        return lines.joined(separator: "\n")
    }

    /// 读取某章最新一份可修订草稿（含作者历次意见）。对话要“改上一版”时先取全文，
    /// 再让模型用 propose_draft 提交完整新版；不能靠历史对话里的记忆改稿。
    static func getLatestDraft(store: ProjectStore, chapter: Int? = nil) -> AgentTool {
        AgentTool(
            name: "get_latest_draft",
            description: "读取某章最新一份可修订的草稿提案（含版本、主线、作者历次修改意见与全文）。作者要求“改上一版/按意见修”时先用它，再用 propose_draft 提交完整新版。chapter 省略则取当前写作章。",
            parametersJSON: """
            {"type":"object","properties":{"chapter":{"type":"integer","description":"章号；省略取当前写作章"}}}
            """
        ) { args in
            struct P: Decodable { let chapter: Int? }
            let p = try decode(P.self, args)
            return await MainActor.run {
                let n = p.chapter ?? chapter ?? store.currentChapter
                return latestDraftDescription(store: store, chapter: n)
            }
        }
    }

    /// 供工具与自检共用的同步实现（纯读，不改账本）
    @MainActor
    static func latestDraftDescription(store: ProjectStore, chapter n: Int) -> String {
        guard let proposal = store.latestAnyDraftProposal(for: n),
              let draft = store.draftPayload(of: proposal) else {
            return "第\(n)章还没有可修订的草稿提案。先写一版草稿，或直接调用 propose_draft 提交新草稿。"
        }
        let feedback = draft.feedbackHistory.isEmpty
            ? "（还没有作者修改意见）"
            : draft.feedbackHistory.map { "v\($0.fromVersion) 作者意见：\($0.feedback)" }.joined(separator: "\n")
        let text = draft.text.count > 24000
            ? String(draft.text.prefix(24000)) + "\n…（全文过长，已截断；修订时请向作者确认未读部分）"
            : draft.text
        return """
        第\(n)章草稿 v\(draft.version)（\(proposal.status.rawValue)｜\(WordStats.chineseCount(draft.text)) 字）
        主线：\(draft.mainline.isEmpty ? "（未记录）" : draft.mainline)
        作者历次意见：
        \(feedback)

        当前全文：
        \(text)
        """
    }

    static func getClues(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "get_clues",
            description: "读取伏笔台账全文。",
            parametersJSON: """
            {"type":"object","properties":{}}
            """
        ) { _ in
            let clues = await MainActor.run { store.clues }
            guard !clues.isEmpty else { return "台账为空。" }
            return clues.map { c in
                "[\(c.id)] \(c.title)｜\(c.status.rawValue)｜埋于第\(c.plantedChapter)章 最近动作第\(c.lastActionChapter)章｜节奏：\(c.timing.rawValue)｜\(c.detail)"
            }.joined(separator: "\n")
        }
    }

    static func getOutline(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "get_outline",
            description: "读取故事线 + 时间线事件（含作者真相/读者已知）。",
            parametersJSON: """
            {"type":"object","properties":{}}
            """
        ) { _ in
            let (lines, events) = await MainActor.run { (store.storylines, store.timelineEvents) }
            var out = "故事线：\n" + (lines.isEmpty ? "（空）" : lines.map { "[\($0.id)] \($0.name)（\($0.kind.rawValue)\($0.isThroughLine ? "·贯穿" : "")）" }.joined(separator: "\n"))
            out += "\n事件：\n" + (events.isEmpty ? "（空）" : events.map { "[\($0.id)] 第\($0.chapter)章 真相：\($0.objectiveFact)｜读者已知：\($0.revealed ? $0.readerKnowledge : "未揭示")" }.joined(separator: "\n"))
            return out
        }
    }

    static func getCanon(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "get_canon",
            description: "读取设定文档。",
            parametersJSON: """
            {"type":"object","properties":{}}
            """
        ) { _ in
            let canon = await MainActor.run { store.canonSections }
            guard !canon.isEmpty else { return "设定为空。" }
            return canon.map { "## \($0.title)（\($0.certainty.rawValue)）\n\(String($0.content.prefix(3000)))" }.joined(separator: "\n\n")
        }
    }

    static func getFacts(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "get_facts",
            description: "读取截至某章仍有效的双时态事实。",
            parametersJSON: """
            {"type":"object","properties":{"at_chapter":{"type":"integer"}},"required":["at_chapter"]}
            """
        ) { args in
            struct P: Decodable { let at_chapter: Int }
            let p = try decode(P.self, args)
            let facts = await MainActor.run {
                store.facts.filter {
                    $0.isValid(atChapter: p.at_chapter)
                        && !$0.subject.trimmingCharacters(in: .whitespaces).isEmpty
                        && !$0.object.trimmingCharacters(in: .whitespaces).isEmpty
                }
            }
            guard !facts.isEmpty else { return "暂无事实。" }
            return facts.map { "[第\($0.fromChapter)章] \($0.subject) \($0.predicate) \($0.object)\($0.publicToReader ? "" : "（读者未知）")" }.joined(separator: "\n")
        }
    }

    /// 资料库检索：跨正文/设定/档案卡/伏笔/事实/时间线做关键词 + 向量混合召回。
    /// 对话与审校都靠它把「书里到底写过什么」找回来；只读，不产生提案。
    static func searchKnowledge(store: ProjectStore, config: AgentConfig? = nil) -> AgentTool {
        AgentTool(
            name: "search_knowledge",
            description: "检索本书资料库（正文/设定/档案卡/伏笔/记忆事实/时间线/故事线/阶段）。回答书内问题前先用它找证据；返回带来源的行。query 用具体名词（人名/物件/地点/伏笔名），limit 默认 6。",
            parametersJSON: """
            {"type":"object","properties":{"query":{"type":"string","description":"要查的具体问题或关键词"},"limit":{"type":"integer","description":"返回条数，默认 6，最大 12"}},"required":["query"]}
            """
        ) { args in
            struct Payload: Decodable { let query: String; let limit: Int? }
            let p = try decode(Payload.self, args)
            let limit = min(12, max(1, p.limit ?? 6))
            let hits = await KnowledgeEngine.search(store: store, query: p.query,
                                                    limit: limit, config: config ?? AgentConfig.load())
            guard !hits.isEmpty else { return "资料库里没有找到与「\(p.query)」相关的内容。" }
            return hits.map { hit in
                let chapter = hit.chunk.chapter.map { "第\($0)章" } ?? hit.chunk.kind.rawValue
                return "【\(hit.chunk.citation)】\n\(hit.chunk.text)\n（来源：\(chapter)｜相关度 \(String(format: "%.2f", hit.score))）"
            }.joined(separator: "\n\n---\n\n")
        }
    }

    /// 把按章绑定的工具版本替换进工具面（单点实现，供工具循环与围栏 JSON 回退共用）
    static func bindChapter(tools: [AgentTool], store: ProjectStore, chapter: Int?) -> [AgentTool] {
        // 0 章/无章号不是合法绑定目标：否则卷级任务的骨架会静默落到「第 0 章」
        guard let n = chapter, n > 0 else { return tools }
        var out = tools
        let bindings: [(String, AgentTool)] = [
            ("get_chapter_skeleton", getChapterSkeleton(store: store, chapter: n)),
            ("get_latest_draft", getLatestDraft(store: store, chapter: n)),
            ("propose_skeleton", proposeSkeleton(store: store, chapter: n)),
            ("propose_draft", proposeDraft(store: store, chapter: n)),
            ("propose_memory", proposeMemory(store: store, chapter: n)),
            ("propose_dossier", proposeDossier(store: store, chapter: n)),
            ("propose_validation", proposeValidation(store: store, chapter: n)),
            ("propose_deslop", proposeDeslop(store: store, chapter: n)),
        ]
        for (name, tool) in bindings {
            if let idx = out.firstIndex(where: { $0.name == name }) {
                out[idx] = tool
            }
        }
        return out
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let dec = JSONDecoder()
        do {
            return try dec.decode(T.self, from: Data(json.utf8))
        } catch {
            throw AgentError.badResponse("工具参数 JSON 不合法：\(error.localizedDescription)")
        }
    }
}
