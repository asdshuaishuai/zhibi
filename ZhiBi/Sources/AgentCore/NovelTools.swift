import Foundation

/// 宿主提供的工具面。铁律：
/// 1. 只存在 propose_*（提案）与只读查询工具——**不存在任何写正文的工具**；
/// 2. 工具执行 = 创建提案进收件箱，回复模型"等待作者确认"，模型口头声明不算采纳。
enum NovelTools {
    private static let timingMap = ["immediate": ClueTiming.immediate, "near_term": ClueTiming.nearTerm, "mid_arc": ClueTiming.midArc, "slow_burn": ClueTiming.slowBurn, "endgame": ClueTiming.endgame]
    private static let scaleMap = ["small": ClueScale.small, "medium": ClueScale.medium, "major": ClueScale.major]

    static func all(store: ProjectStore, chapter: Int = 0) -> [AgentTool] {
        [
            proposeOutlineEvents(store: store),
            proposeStorylines(store: store),
            proposeClues(store: store),
            proposeSkeleton(store: store, chapter: chapter),
            proposeDraft(store: store, chapter: chapter),
            proposeMemory(store: store, chapter: chapter),
            proposeValidation(store: store, chapter: chapter),
            proposeDeslop(store: store, chapter: chapter),
            proposeMemo(store: store),
            proposeCanon(store: store),
            getChapter(store: store),
            getClues(store: store),
            getOutline(store: store),
            getCanon(store: store),
            getFacts(store: store),
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
            // E 编号基于已有最大值递增并查重，避免顶掉已有事件
            let events: [TimelineEvent] = await MainActor.run {
                var used = Set(store.timelineEvents.map { "\($0.id)|\($0.chapter)" })
                var nextNumber = (store.timelineEvents.compactMap { e -> Int? in
                    guard e.id.hasPrefix("E"), let n = Int(e.id.dropFirst()) else { return nil }
                    return n
                }.max() ?? 0) + 1
                var out: [TimelineEvent] = []
                for e in p.events {
                    var id = e.id ?? ""
                    if id.isEmpty || used.contains("\(id)|\(e.chapter)") {
                        repeat {
                            id = String(format: "E%02d", nextNumber)
                            nextNumber += 1
                        } while used.contains("\(id)|\(e.chapter)")
                    }
                    used.insert("\(id)|\(e.chapter)")
                    out.append(TimelineEvent(
                        id: id,
                        chapter: e.chapter,
                        objectiveFact: e.objective_fact,
                        readerKnowledge: e.reader_knowledge,
                        revealed: e.revealed ?? false,
                        storylineIDs: e.storyline_ids ?? []
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
            let lines = p.storylines.enumerated().map { i, s -> Storyline in
                Storyline(id: s.id ?? "L\(String(format: "%02d", i + 1))", name: s.name,
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
            description: "提交章节骨架提案。你不写正文，只规划这章要完成什么：3-6 个节拍（beats），每拍一句人话说明要发生什么 + 功能定位；章尾钩子；硬交付项；禁止项；伏笔触点合同（clue_id + action: plant/develop/reveal）。揭1埋1：本章每回收一个伏笔，尽量同时埋1-2个新伏笔。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"beats":{"type":"array","minItems":3,"maxItems":6,"items":{"type":"object","properties":{"summary":{"type":"string"},"purpose":{"type":"string"},"clue_ids":{"type":"array","items":{"type":"string"}},"suggested_words":{"type":"integer"}},"required":["summary"]}},"end_hook":{"type":"string"},"must_deliver":{"type":"array","items":{"type":"string"}},"must_avoid":{"type":"array","items":{"type":"string"}},"clue_touches":{"type":"array","items":{"type":"object","properties":{"clue_id":{"type":"string"},"action":{"type":"string","enum":["plant","develop","reveal"]},"requirement":{"type":"string"}},"required":["clue_id","action"]}}},"required":["beats","end_hook"]}
            """
        ) { args in
            struct Payload: Decodable {
                struct B: Decodable {
                    let summary: String
                    let purpose: String?
                    let clue_ids: [String]?
                    let suggested_words: Int?
                }
                struct T: Decodable {
                    let clue_id: String
                    let action: String
                    let requirement: String?
                }
                let note: String?
                let beats: [B]
                let end_hook: String
                let must_deliver: [String]?
                let must_avoid: [String]?
                let clue_touches: [T]?
            }
            let p = try decode(Payload.self, args)
            let actionMap = ["plant": ClueActionKind.plant, "develop": .develop, "reveal": .reveal]
            let sk = ChapterSkeleton(
                beats: p.beats.map { b in
                    Beat(summary: b.summary, purpose: b.purpose ?? "", clueIDs: b.clue_ids ?? [], suggestedWords: b.suggested_words ?? 0)
                },
                endHook: p.end_hook,
                mustDeliver: p.must_deliver ?? [],
                mustAvoid: p.must_avoid ?? [],
                clueTouches: (p.clue_touches ?? []).map { t in
                    ClueTouch(clueID: t.clue_id, action: actionMap[t.action] ?? .plant, requirement: t.requirement ?? "")
                },
                proposedByAI: true
            )
            await store.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: chapter,
                                               title: "第\(chapter ?? 0)章 骨架（\(sk.beats.count) 拍）",
                                               note: p.note ?? "", payload: .skeleton(sk)))
            return "已登记为提案「章节骨架」，等待作者在收件箱确认。作者会在此骨架上修改与填写，正文由作者亲笔完成。"
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
            report.lint = await MainActor.run { AILint.scan(store.chapter(chapter)?.prose ?? "") }
            await store.addProposal(AIProposal(capability: .deslop, chapterNumber: chapter,
                                               title: "第\(chapter)章 去AI味建议（\(suggestions.count) 处，\(p.grade)）",
                                               note: p.note ?? "", payload: .deslop(report)))
            return "已登记为提案「去AI味建议」，逐条采纳与否由作者决定。"
        }
    }

    static func proposeDraft(store: ProjectStore, chapter: Int) -> AgentTool {
        AgentTool(
            name: "propose_draft",
            description: "提交整章草稿提案（你亲笔的初稿/修订稿）。全文放入 text，不要分段输出到对话里。这是提案：作者审查、给修改意见、采纳之后才会进入正文。每次修订都提交完整全文（不是补丁）。",
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

    static func proposeMemo(store: ProjectStore) -> AgentTool {
        AgentTool(
            name: "propose_memo",
            description: "提交写作备忘提案（召回后给作者的写作提醒，2-3 条以内，人话）。",
            parametersJSON: """
            {"type":"object","properties":{"note":{"type":"string"},"text":{"type":"string"}},"required":["text"]}
            """
        ) { args in
            struct Payload: Decodable { let note: String?; let text: String }
            let p = try decode(Payload.self, args)
            await store.addProposal(AIProposal(capability: .recallMemo, title: "写作备忘", note: p.note ?? "", payload: .memo(p.text)))
            return "已登记为提案「写作备忘」。"
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
            description: "读取某章正文（作者亲笔）。用于验证时对照原文取证。",
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
            let facts = await MainActor.run { store.facts.filter { $0.isValid(atChapter: p.at_chapter) } }
            guard !facts.isEmpty else { return "暂无事实。" }
            return facts.map { "[第\($0.fromChapter)章] \($0.subject) \($0.predicate) \($0.object)\($0.publicToReader ? "" : "（读者未知）")" }.joined(separator: "\n")
        }
    }

    /// 把按章绑定的工具版本替换进工具面（单点实现，供工具循环与围栏 JSON 回退共用）
    static func bindChapter(tools: [AgentTool], store: ProjectStore, chapter: Int?) -> [AgentTool] {
        guard let n = chapter else { return tools }
        var out = tools
        let bindings: [(String, AgentTool)] = [
            ("propose_skeleton", proposeSkeleton(store: store, chapter: n)),
            ("propose_draft", proposeDraft(store: store, chapter: n)),
            ("propose_memory", proposeMemory(store: store, chapter: n)),
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
