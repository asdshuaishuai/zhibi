import Foundation
import OpenAgentSDK

/// AI 任务编排器。所有能力都走同一通道：
/// 造包 → 组 prompt → OpenAgentSDK agent（工具循环）→ 提案落收件箱。
/// 没有"写正文"通道——这是结构保证，不是口头约定。
@MainActor
final class AIService: ObservableObject {
    @Published var running = false
    @Published var runningCapability: AICapability?
    @Published var streamPreview = ""
    @Published var lastError: String?
    @Published var lastToolLog: [String] = []
    /// 上一次运行新登记的提案数（nil = 本次运行未统计/无新增）
    @Published var lastRunNewProposals: Int?

    /// 供应商连通性预检：Key 缺失 / 远程明文 HTTP（API Key 会明文出网）/ 端点非法
    func validateConfig(_ config: AgentConfig) -> String? {
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Base URL 为空——在设置里填模型端点（或从目录选供应商）。"
        }
        guard let endpoint = URL(string: trimmed) else {
            return "Base URL 无效：\(trimmed)"
        }
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(endpoint.host?.lowercased() ?? "")
        if endpoint.scheme?.lowercased() == "http", !isLoopback {
            return "远程 API 地址不要用 http://（API Key 会明文出网），请改用 https://；本地 Ollama 不受限制。"
        }
        if config.apiKey.isEmpty, !isLoopback {
            return AgentError.noAPIKey.localizedDescription
        }
        return nil
    }

    /// 任务 → 该能力可用的工具名子集。
    /// 抽成静态单一真相源：生产路径与自检共用同一份映射，否则自检抄一份就等于没测。
    static func toolNames(for capability: AICapability) -> Set<String> {
        switch capability {
        case .framework:
            return ["propose_storylines", "propose_outline_events", "propose_canon", "get_canon"]
        case .outlineTimeline:
            return ["propose_storylines", "propose_outline_events", "get_outline", "get_canon"]
        case .clueLedger:
            return ["propose_clues", "get_clues", "get_outline", "get_chapter"]
        case .chapterSkeleton:
            return ["propose_skeleton", "propose_clues", "get_clues", "get_outline", "get_facts"]
        case .chapterDraft:
            return ["propose_draft", "get_clues", "get_canon", "get_facts", "get_outline"]
        case .chapterRevise:
            return ["propose_draft"]
        case .memoryExtract:
            return ["propose_memory", "propose_clues", "get_clues", "get_facts"]
        case .validation:
            return ["propose_validation", "get_chapter", "get_clues", "get_facts", "get_canon", "get_outline"]
        case .continuityAudit:
            return ["propose_continuity", "get_chapter", "get_clues", "get_facts", "get_canon", "get_outline"]
        case .outlineSync:
            return ["propose_outline_updates", "propose_outline_events", "get_outline", "get_chapter", "get_clues"]
        case .deslop:
            return ["propose_deslop"]
        case .recallMemo:
            return ["propose_memo"]
        }
    }

    /// 任务 → 该能力可用的工具子集
    private func tools(for capability: AICapability, store: ProjectStore, chapter: Int?) -> [AgentTool] {
        let all = NovelTools.all(store: store)
        let needed = Self.toolNames(for: capability)
        let selected = all.filter { needed.contains($0.name) }
        return NovelTools.bindChapter(tools: selected, store: store, chapter: chapter)
    }

    /// 通用执行入口
    func run(capability: AICapability, store: ProjectStore, config: AgentConfig, chapter: Int?, userMessage: String) async {
        guard !running else { return }
        running = true
        runningCapability = capability
        streamPreview = ""
        lastError = nil
        lastToolLog = []
        lastRunNewProposals = nil
        defer {
            running = false
            runningCapability = nil
        }

        do {
            if let problem = validateConfig(config) {
                lastError = problem
                return
            }
            let toolset = tools(for: capability, store: store, chapter: chapter)
            // 创作法典集中注入：流派契约 + 网文创作法 + 传统文学创作法，按能力裁剪。
            // 骨架任务书里已经内嵌（位置更靠前、还带着近章钩子形态），这里跳过避免重复。
            let taskMessage: String
            if capability == .chapterSkeleton {
                taskMessage = userMessage
            } else {
                let written = store.chapters.filter { !$0.prose.isEmpty }.count
                taskMessage = userMessage + "\n\n---\n\n## 创作法典（按它的标准干活）\n"
                    + PromptLibrary.craft(for: capability, genre: store.project.genre,
                                          written: written, target: store.project.targetChapters)
            }
            let agent = createAgent(options: AgentOptions(
                apiKey: config.apiKey,
                model: config.model,
                baseURL: config.baseURL,
                provider: .openai,
                systemPrompt: PromptLibrary.systemInstruction(for: capability),
                maxTurns: 12,
                permissionMode: .bypassPermissions,
                tools: ProposalToolBridge.sdkTools(toolset)))
            let proposalsBefore = store.proposals.count
            // MiniMax 等模型会把思考内容以 <think>…</think> 内嵌在正文增量里，展示层滤掉
            var previewFilter = ThinkTagFilter()
            var runProblems: [String] = []

            for await message in agent.stream(taskMessage) {
                switch message {
                case .partialMessage(let data):
                    streamPreview += previewFilter.push(data.text)
                    if streamPreview.count > 4000 { streamPreview = String(streamPreview.suffix(4000)) }
                case .toolUse(let data):
                    lastToolLog.append("🛠 \(data.toolName)")
                case .toolResult(let data):
                    lastToolLog.append("↳ \(String(data.content.prefix(120)))")
                case .result(let data):
                    streamPreview += previewFilter.flush()
                    if streamPreview.count > 4000 { streamPreview = String(streamPreview.suffix(4000)) }
                    if data.subtype != .success {
                        runProblems.append(data.text)
                    }
                default:
                    break
                }
            }

            // 兜底：若模型没用工具，解析围栏 JSON 并代为登记提案
            if store.proposals.count == proposalsBefore {
                if let fallback = FallbackProposer.parse(streamPreview) {
                    try await FallbackProposer.apply(fallback, store: store, chapter: chapter)
                    lastToolLog.append("📥 已从文本产出中解析并登记提案（无工具调用回退）")
                } else if lastToolLog.isEmpty {
                    // 模型只回了纯文本：登记为备忘提案，不让产出丢失
                    let text = streamPreview.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        await store.addProposal(AIProposal(
                            capability: capability, chapterNumber: chapter,
                            title: "\(capability.rawValue)（文本产出）", note: "模型未调用工具，产出以文本提案呈现",
                            payload: .memo(text)))
                    }
                }
            }

            if !runProblems.isEmpty, store.proposals.count == proposalsBefore {
                lastError = runProblems.joined(separator: "；")
            }
            lastRunNewProposals = max(0, store.proposals.count - proposalsBefore)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 具体能力入口

    /// 新书创建即触发：基于最小输入（书名/题材/一句话核心）搭主线 + 背景框架。
    /// 全部走提案通道，作者在收件箱审过才算数——机制与其它能力完全一致。
    func runBootstrapFramework(store: ProjectStore, config: AgentConfig, premise: String, notes: String = "") async {
        let canon = store.canonSections.map { "《\($0.title)》\($0.content)" }.joined(separator: "\n\n")
        await run(capability: .framework, store: store, config: config, chapter: nil,
                  userMessage: PromptLibrary.bootstrapFrameworkTask(
                      premise: premise, canon: canon, notes: notes,
                      targetChapters: store.project.targetChapters))
    }

    func runOutlineTimeline(store: ProjectStore, config: AgentConfig, notes: String) async {
        let canon = store.canonSections.map { "《\($0.title)》\($0.content)" }.joined(separator: "\n\n")
        let premise = "\(store.project.title)｜题材：\(store.project.genre)｜核心：\(store.project.premise)"
        await run(capability: .outlineTimeline, store: store, config: config, chapter: nil,
                  userMessage: PromptLibrary.outlineTimelineTask(premise: premise, canon: canon, notes: notes, targetChapters: store.project.targetChapters))
    }

    func runClueInventory(store: ProjectStore, config: AgentConfig, scope: String) async {
        let proseDigest = store.chapters.compactMap { ch -> String? in
            guard !ch.prose.isEmpty else { return nil }
            return "第\(ch.number)章《\(ch.title)》节选：\(String(ch.prose.suffix(1200)))"
        }.joined(separator: "\n\n")
        await run(capability: .clueLedger, store: store, config: config, chapter: nil,
                  userMessage: """
                  请通读以下已有正文节选，盘点其中埋下但尚未收束的伏笔/线索/承诺，用 propose_clues 提案登记台账。已有台账（\(store.clues.count) 条）之外的才登记；已有的不要重复。
                  盘点范围：\(scope.isEmpty ? "全部已有章节" : scope)
                  \(proseDigest.isEmpty ? "（还没有正文）" : String(proseDigest.prefix(14000)))
                  """)
    }

    func runSkeleton(store: ProjectStore, config: AgentConfig, chapter n: Int, directive: String) async {
        let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: config.contextTokenBudget)
        let title = store.chapter(n)?.title ?? ""
        let written = store.chapters.filter { !$0.prose.isEmpty }.count
        let craft = PromptLibrary.craft(for: .chapterSkeleton, genre: store.project.genre,
                                        written: written, target: store.project.targetChapters)
        // 近几章的钩子形态：让 AI 有意识地轮换，别连续三章同型（套版感是 AI 味的一种）
        let recentHooks = store.chapters
            .filter { $0.number < n && $0.skeleton != nil }
            .sorted { $0.number > $1.number }
            .prefix(4)
            .compactMap { ch -> String? in
                guard let sk = ch.skeleton else { return nil }
                if !sk.hookKind.isEmpty { return "第\(ch.number)章：\(sk.hookKind)" }
                guard !sk.endHook.isEmpty else { return nil }
                return CraftCodex.classifyHook(sk.endHook).map { "第\(ch.number)章：\($0.rawValue)" }
            }
            .reversed()
        // 已有骨架就先过一遍闸门，把问题清单喂回去——这一版必须比上一版合格（迭代式强化）
        var gateReport = ""
        if let existing = store.chapter(n)?.skeleton, !existing.beats.isEmpty {
            let gate = SkeletonGate.evaluate(existing, store: store, chapter: n)
            if !gate.issues.isEmpty {
                gateReport = "（闸门 \(gate.score)/100）\n" + gate.issues.map {
                    "[\($0.severity.rawValue)] \($0.code)：\($0.message) → \($0.suggestion)"
                }.joined(separator: "\n")
            }
        }
        await run(capability: .chapterSkeleton, store: store, config: config, chapter: n,
                  userMessage: PromptLibrary.chapterSkeletonTask(
                    chapter: n, chapterTitle: title, pack: pack, authorDirective: directive,
                    craft: craft, gateReport: gateReport,
                    prevHookKinds: recentHooks.joined(separator: "\n")))
    }

    /// 卷骨架：一次规划连续多章的弧光，作者认可后再逐章细化。
    /// 解决"逐章搭骨架只见树木不见森林"——卷弧结构（起承转合 + 赌注递增）必须在这一层设计。
    func runVolumeSkeleton(store: ProjectStore, config: AgentConfig, from start: Int, to end: Int, directive: String) async {
        guard end >= start else {
            lastError = "结束章不能早于起始章。"
            return
        }
        if end - start + 1 > 40 {
            lastError = "一次最多规划 40 章（再多模型会开始编流水账）。"
            return
        }
        let pack = ContextPackBuilder.build(store: store, forChapter: start, budget: config.contextTokenBudget)
        let planned = store.timelineEvents.filter { $0.chapter >= start && $0.chapter <= end }
            .map { "[\($0.id)] 第\($0.chapter)章：\($0.objectiveFact)" + ($0.revealed ? "" : "（读者未知）") }
        let lines = store.storylines.map { "[\($0.id)] \($0.name)（\($0.kind.rawValue)\($0.isThroughLine ? "·贯穿" : "")·\($0.status.rawValue)）" }
        let dues = store.activeClues(currentChapter: end).filter { $0.isOverdue(currentChapter: end) }
            .map { "[\($0.id)] \($0.title)（已逾期，节奏 \($0.timing.rawValue)）" }
        var existing = "故事线：\n" + (lines.isEmpty ? "（空）" : lines.joined(separator: "\n"))
        existing += "\n\n这一段原本计划的事件：\n" + (planned.isEmpty ? "（大纲里这一段没有排事件）" : planned.joined(separator: "\n"))
        if !dues.isEmpty {
            existing += "\n\n到第\(end)章为止已逾期的伏笔（这一段必须处理掉一部分）：\n" + dues.joined(separator: "\n")
        }
        let written = store.chapters.filter { !$0.prose.isEmpty }.count
        await run(capability: .chapterSkeleton, store: store, config: config, chapter: nil,
                  userMessage: PromptLibrary.volumeSkeletonTask(
                    fromChapter: start, toChapter: end, pack: pack, authorDirective: directive,
                    craft: PromptLibrary.craft(for: .chapterSkeleton, genre: store.project.genre,
                                               written: written, target: store.project.targetChapters),
                    existingOutline: existing))
    }

    /// 全书连贯性审查：宿主确定性扫描（零成本）+ LLM 补六类需要理解的错误 + 埋点修复方案
    func runContinuityAudit(store: ProjectStore, config: AgentConfig) async {
        if let problem = validateConfig(config) {
            lastError = problem
            return
        }
        let asOf = store.currentChapter
        // 先跑确定性审查并把结果落一份提案：即使 LLM 失败，作者也拿得到机械性错误的清单
        let deterministic = ContinuityAuditor.audit(store: store, throughChapter: asOf)
        await store.addProposal(AIProposal(
            capability: .continuityAudit, chapterNumber: asOf,
            title: "全书连贯性·确定性体检（截至第\(asOf)章，\(deterministic.issues.count) 条，零 AI 成本）",
            note: deterministic.summary,
            payload: .report(ValidationReport(chapter: asOf, deterministicIssues: deterministic.issues, aiIssues: []))))
        if !deterministic.clueFixes.isEmpty {
            await store.addProposal(AIProposal(
                capability: .continuityAudit, chapterNumber: asOf,
                title: "埋点修复方案（\(deterministic.clueFixes.count) 条，可逐条采纳）",
                note: "伏笔台账的烂账。采纳即改台账，不动正文。",
                payload: .clueFixes(deterministic.clueFixes)))
        }
        await run(capability: .continuityAudit, store: store, config: config, chapter: nil,
                  userMessage: PromptLibrary.continuityAuditTask(
                    asOfChapter: asOf,
                    deterministicFindings: deterministic.issues.prefix(40).map {
                        "[\($0.severity.rawValue)·\($0.category)] \($0.message)" + ($0.evidence.isEmpty ? "" : "｜证据：\(String($0.evidence.prefix(80)))")
                    }.joined(separator: "\n"),
                    digest: bookDigest(store: store, asOf: asOf),
                    craft: PromptLibrary.craft(for: .continuityAudit, genre: store.project.genre)))
    }

    /// 大纲同步：把静态计划对账成随剧情推进的活文档
    func runOutlineSync(store: ProjectStore, config: AgentConfig) async {
        if let problem = validateConfig(config) {
            lastError = problem
            return
        }
        let report = OutlineSync.sync(store: store)
        // 确定性对账结果先落一份（作者可以只看这份，不花 token）
        await store.addProposal(AIProposal(
            capability: .outlineSync, chapterNumber: report.asOfChapter,
            title: "大纲对账·确定性报告（截至第\(report.asOfChapter)章）",
            note: report.summary,
            payload: .memo(outlineSyncText(report))))
        await run(capability: .outlineSync, store: store, config: config, chapter: nil,
                  userMessage: PromptLibrary.outlineSyncTask(
                    asOfChapter: report.asOfChapter,
                    deterministicFindings: outlineSyncText(report),
                    craft: PromptLibrary.craft(for: .outlineSync, genre: store.project.genre)))
    }

    /// 全书梗概：给连贯性审查取证用（摘要优先，没有摘要才退到正文节选）
    private func bookDigest(store: ProjectStore, asOf: Int) -> String {
        var lines: [String] = []
        lines.append("【故事线】")
        lines += store.storylines.map {
            "[\($0.id)] \($0.name)（\($0.kind.rawValue)\($0.isThroughLine ? "·贯穿" : "")·\($0.status.rawValue)）"
                + ($0.plannedPayoffChapter.map { "｜计划收束第\($0)章" } ?? "") + "：\($0.notes)"
        }
        lines.append("\n【各章实际发生了什么】")
        for ch in store.chapters where ch.number <= asOf {
            if let s = ch.summary {
                lines.append("第\(ch.number)章《\(ch.title)》：\(s.summary)")
                if !s.keyEvents.isEmpty { lines.append("  关键事件：" + s.keyEvents.joined(separator: "；")) }
            } else if !ch.prose.isEmpty {
                lines.append("第\(ch.number)章《\(ch.title)》（无摘要，正文首尾节选）：\(String(ch.prose.prefix(300)))…\(String(ch.prose.suffix(200)))")
            }
        }
        lines.append("\n【伏笔台账】")
        lines += store.clues.map {
            "[\($0.id)] \($0.title)｜\($0.status.rawValue)｜埋于第\($0.plantedChapter)章"
                + ($0.targetPayoffChapter.map { "｜计划第\($0)章兑现" } ?? "") + "｜最近动作第\($0.lastActionChapter)章"
        }
        let text = lines.joined(separator: "\n")
        return String(text.prefix(28000))
    }

    /// 大纲对账报告 → 人读文本（既是提案内容，也是喂给 LLM 的取证基础）
    private func outlineSyncText(_ r: OutlineSyncReport) -> String {
        var lines: [String] = [r.summary, ""]
        lines.append("【剧情线健康度】")
        lines += r.lineHealth.map {
            "[\($0.storylineID)] \($0.name)（\($0.kindRaw)）：\($0.state.rawValue)｜最后动静第\($0.lastSeenChapter)章，静默 \($0.dormantChapters) 章｜计划事件 \($0.plannedEvents)，已证实 \($0.matchedEvents)，逾期未兑现 \($0.overdueEvents)"
                + ($0.note.isEmpty ? "" : "\n  \($0.note)")
        }
        lines.append("\n【计划 vs 实际】")
        lines += r.eventSync.map {
            "[\($0.eventID)] 计划第\($0.plannedChapter)章 → \($0.status)"
                + ($0.matchedChapter.map { "（实际第\($0)章）" } ?? "")
                + "｜匹配度 \(String(format: "%.2f", $0.similarity))"
                + ($0.evidence.isEmpty ? "" : "｜证据：\(String($0.evidence.prefix(60)))")
        }
        if !r.stageProgress.isEmpty {
            lines.append("\n【阶段进度】")
            lines += r.stageProgress.map {
                "阶段\($0.stageID)《\($0.name)》第\($0.chapterStart)-\($0.chapterEnd)章：完成度 \(Int($0.completionRatio * 100))%｜字数 \($0.wordsWritten)/\($0.wordsPlanned)｜事件 \($0.eventsDone)/\($0.eventsTotal)"
                    + ($0.note.isEmpty ? "" : "｜\($0.note)")
            }
        }
        if !r.divergences.isEmpty {
            lines.append("\n【偏差】")
            lines += r.divergences.prefix(30).map { "[\($0.severity.rawValue)·\($0.category)] \($0.message)" }
        }
        if !r.suggestedUpdates.isEmpty {
            lines.append("\n【宿主已生成的更新建议（\(r.suggestedUpdates.count) 条）】")
            lines += r.suggestedUpdates.prefix(30).map { "\($0.kind.rawValue)：\($0.reason)" }
        }
        return String(lines.joined(separator: "\n").prefix(24000))
    }

    func runMemoryExtract(store: ProjectStore, config: AgentConfig, chapter n: Int) async {
        guard let ch = store.chapter(n), !ch.prose.isEmpty else {
            lastError = "第\(n)章还没有正文，无可提取。"
            return
        }
        let knownClues = store.clues.map { "[\($0.id)] \($0.title)：\($0.detail)" }.joined(separator: "\n")
        let knownFacts = store.facts.filter { $0.fromChapter >= n }.map { "\($0.subject) \($0.predicate) \($0.object)" }.joined(separator: "\n")
        let notes = ch.noteList
        var message = PromptLibrary.memoryExtractTask(chapter: n, prose: ch.prose, knownClues: knownClues, knownFacts: knownFacts)
        if !notes.isEmpty {
            message += "\n\n## 作者的随手记（本章写作时顺手记的候选，请核实正文后归档或修正）\n" + notes.map { "- \($0)" }.joined(separator: "\n")
        }
        await run(capability: .memoryExtract, store: store, config: config, chapter: n, userMessage: message)
    }

    func runValidation(store: ProjectStore, config: AgentConfig, chapter n: Int, overrideText: String? = nil) async {
        // 先做供应商预检（Key 等），避免确定性报告先落库成永不合并的孤儿
        if let problem = validateConfig(config) {
            lastError = problem
            return
        }
        if let overrideText, !overrideText.isEmpty {
            // 草稿模式：直接审稿本文本（确定性体检跳过——草稿未入库）
            let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: config.contextTokenBudget)
            await run(capability: .validation, store: store, config: config, chapter: n,
                      userMessage: PromptLibrary.validationTask(chapter: n, prose: overrideText, skeleton: "", pack: pack, draftMode: true))
            return
        }
        guard let ch = store.chapter(n), !ch.prose.isEmpty else {
            lastError = "第\(n)章还没有正文，无法验证。"
            return
        }
        var report = await Validator.deterministicReport(store: store, chapter: n)
        report.checkedAt = Date()
        // 确定性报告先落一份（AI 审校提案会合并它）
        await store.addProposal(AIProposal(
            capability: .validation, chapterNumber: n,
            title: "第\(n)章 确定性体检（\(report.deterministicIssues.count) 条，零 AI 成本）",
            note: "骨架覆盖/伏笔合同/AI味扫描/字数——本地代码检查，AI 审校报告随后合并。",
            payload: .report(report)))

        let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: config.contextTokenBudget)
        var skeletonText = ""
        if let sk = ch.skeleton {
            skeletonText = sk.beats.enumerated().map { i, b in "\(i + 1). \(b.summary)（\(b.purpose)）" }.joined(separator: "\n")
            if !sk.endHook.isEmpty { skeletonText += "\n章尾钩子：\(sk.endHook)" }
            for t in sk.clueTouches { skeletonText += "\n伏笔触点：[\(t.clueID)] \(t.action.rawValue) —— \(t.requirement)" }
        }
        await run(capability: .validation, store: store, config: config, chapter: n,
                  userMessage: PromptLibrary.validationTask(chapter: n, prose: ch.prose, skeleton: skeletonText, pack: pack))
    }

    func runDeslop(store: ProjectStore, config: AgentConfig, chapter n: Int, overrideText: String? = nil) async {
        let text: String
        if let overrideText, !overrideText.isEmpty {
            text = overrideText
        } else {
            guard let ch = store.chapter(n), !ch.prose.isEmpty else {
                lastError = "第\(n)章还没有正文。"
                return
            }
            text = ch.prose
        }
        let lint = AILint.scan(text)
        await run(capability: .deslop, store: store, config: config, chapter: n,
                  userMessage: PromptLibrary.deslopTask(chapter: n, prose: text, lintSummary: lint, model: config.model))
    }

    // MARK: - 流水线：一键写作 / 按意见修复

    /// 一键成章当前跑到哪一步（空 = 没在跑）
    @Published var pipelineStage: String = ""
    /// 本次一键成章已经完成并落到收件箱的步骤
    @Published var pipelineDone: [String] = []
    /// 需要作者介入的提示（不是错误，别和 lastError 混用）
    @Published var pipelineNote: String = ""

    /// 一键成章：草稿 → 一致性审查 → 去AI味 一路串到底，最后停在「作者采纳」之前。
    ///
    /// 铁律的边界在这里要说清楚：需要人裁决的是「什么进正文」，不是「要不要点四下鼠标」。
    /// 所以中间步骤可以自动串——它们的产出全是提案；但**骨架不代批**，因为骨架是写前契约，
    /// 属于正典决定。没有已批准的骨架时，这一步只出骨架提案然后停下等作者。
    func runAutoPipeline(store: ProjectStore, config: AgentConfig, chapter n: Int, mainline: String) async {
        guard !running else { return }
        pipelineDone = []
        pipelineNote = ""

        guard store.chapter(n)?.skeleton?.humanApproved == true else {
            pipelineStage = "搭骨架"
            await runSkeleton(store: store, config: config, chapter: n, directive: mainline)
            pipelineStage = ""
            if lastError == nil {
                pipelineNote = "骨架提案已就绪。骨架是写前契约，需要你先在收件箱批准——批准后再点一次「一键成章」，草稿 / 一致性审查 / 去AI味会一路串到底。"
            }
            return
        }

        pipelineStage = "写草稿"
        await runDraft(store: store, config: config, chapter: n, mainline: mainline)
        guard lastError == nil,
              let draft = store.latestDraftProposal(for: n).flatMap({ store.draftPayload(of: $0) }) else {
            pipelineStage = ""
            return
        }
        pipelineDone.append("草稿 v\(draft.version)（\(WordStats.chineseCount(draft.text)) 字）")

        // 审查与去AI味都针对**草稿文本**（overrideText），不是已入库的正文——草稿还没进正文
        pipelineStage = "一致性审查"
        await runValidation(store: store, config: config, chapter: n, overrideText: draft.text)
        pipelineDone.append(lastError == nil ? "一致性审查" : "一致性审查（失败，见错误）")

        pipelineStage = "去AI味"
        await runDeslop(store: store, config: config, chapter: n, overrideText: draft.text)
        pipelineDone.append(lastError == nil ? "去AI味" : "去AI味（失败，见错误）")

        pipelineStage = ""
        pipelineNote = "四步都跑完了，产出全在收件箱。读过草稿、按需给意见修复，满意了再采纳入库（采纳前会自动留快照）。"
    }

    func runDraft(store: ProjectStore, config: AgentConfig, chapter n: Int, mainline: String) async {
        let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: config.contextTokenBudget)
        var skeletonText = ""
        if let sk = store.chapter(n)?.skeleton, !sk.beats.isEmpty {
            skeletonText = sk.beats.enumerated().map { i, b in
                var line = "\(i + 1). \(b.summary)（\(b.purpose)\(b.suggestedWords > 0 ? "｜约\(b.suggestedWords)字" : "")）"
                // 场景层要喂给草稿：不喂的话模型只能自己猜空间与视角关系，
                // 猜出来的东西正是连贯性审查后面要抓的错。
                var scene: [String] = []
                if !b.pov.isEmpty { scene.append("视角：\(b.pov)") }
                if !b.location.isEmpty { scene.append("地点：\(b.location)") }
                if !b.timeLabel.isEmpty { scene.append("时间：\(b.timeLabel)") }
                if !b.cast.isEmpty { scene.append("在场：\(b.cast.joined(separator: "、"))") }
                if !b.turn.isEmpty { scene.append("转折：\(b.turn)") }
                if !scene.isEmpty { line += "\n   " + scene.joined(separator: "｜") }
                return line
            }.joined(separator: "\n")
            if !sk.pov.isEmpty { skeletonText += "\n本章主视角：\(sk.pov)（不要漂移；要换视角就分节）" }
            if !sk.endHook.isEmpty { skeletonText += "\n章尾钩子：\(sk.endHook)" + (sk.hookKind.isEmpty ? "" : "（\(sk.hookKind)型）") }
            if !sk.payoffType.isEmpty { skeletonText += "\n本章兑现的爽点：\(sk.payoffType)" }
            if !sk.newExpectation.isEmpty { skeletonText += "\n本章要挂上的新期待：\(sk.newExpectation)" }
            if !sk.mustDeliver.isEmpty { skeletonText += "\n硬交付：" + sk.mustDeliver.joined(separator: "；") }
            if !sk.mustAvoid.isEmpty { skeletonText += "\n禁止：" + sk.mustAvoid.joined(separator: "；") }
            for t in sk.clueTouches { skeletonText += "\n伏笔触点：[\(t.clueID)] \(t.action.rawValue) —— \(t.requirement)" }
        }
        let message = PromptLibrary.draftTask(
            chapter: n,
            title: store.chapter(n)?.title ?? "",
            targetWords: store.project.chapterWordTarget,
            mainline: mainline,
            skeletonText: skeletonText,
            pack: pack,
            model: config.model)
        await run(capability: .chapterDraft, store: store, config: config, chapter: n, userMessage: message)
    }

    /// 不带工具的一轮对话：只要模型的正文文本。
    /// 分段写作要靠它逐块取文本再拼装——如果每块都走 propose_draft，
    /// 一块就会登记一个草稿版本，作者会在收件箱里看到七八个半截草稿。
    private func runTextOnly(store: ProjectStore, config: AgentConfig,
                             capability: AICapability, userMessage: String) async -> String? {
        if let problem = validateConfig(config) {
            lastError = problem
            return nil
        }
        do {
            let agent = createAgent(options: AgentOptions(
                apiKey: config.apiKey,
                model: config.model,
                baseURL: config.baseURL,
                provider: .openai,
                systemPrompt: PromptLibrary.systemInstruction(for: capability),
                maxTurns: 2,
                permissionMode: .bypassPermissions,
                tools: []))
            var filter = ThinkTagFilter()
            var out = ""
            // 这条通道不经过 run()，创作法典要在这里自己注入——否则分段写作整个丢掉流派档案与创作法，
            // 而它恰恰是最需要"怎么写"指导的那条路径。
            let written = store.chapters.filter { !$0.prose.isEmpty }.count
            let taskMessage = userMessage + "\n\n---\n\n## 创作法典（按它的标准干活）\n"
                + PromptLibrary.craft(for: capability, genre: store.project.genre,
                                      written: written, target: store.project.targetChapters)
            for await message in agent.stream(taskMessage) {
                switch message {
                case .partialMessage(let d):
                    out += filter.push(d.text)
                case .result(let d):
                    out += filter.flush()
                    if d.subtype != .success { lastError = d.text }
                default: break
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// 分段写作：按骨架节拍分块生成，逐块带着「已经写出来的结尾」续写，最后拼成**一份**草稿提案。
    ///
    /// 为什么需要它：3000 字以上一次性生成，后半段必然退化——句子开始复读、结尾被草草收掉、
    /// 骨架后几拍被压缩成一两句交代。分块把每块压在模型能稳定发挥的篇幅内，
    /// 而块与块之间靠"上一块的实际结尾"衔接，比一次性写完更连贯。
    /// 产出仍然是一份草稿提案，采纳前不进正文。
    func runDraftByScenes(store: ProjectStore, config: AgentConfig, chapter n: Int,
                          mainline: String, wordsPerChunk: Int = 1200) async {
        guard !running else { return }
        running = true
        runningCapability = .chapterDraft
        streamPreview = ""
        lastError = nil
        lastToolLog = []
        lastRunNewProposals = nil
        defer { running = false; runningCapability = nil }

        guard let sk = store.chapter(n)?.skeleton, !sk.beats.isEmpty else {
            lastError = "分段写作需要先有骨架（按节拍分块）。先搭骨架并批准，或用普通的「写草稿」。"
            return
        }
        let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: config.contextTokenBudget)
        let perChunk = max(400, wordsPerChunk)

        // 按建议字数把节拍打包成块：一块控制在 perChunk 字上下，至少一拍，不让单拍被切开
        var chunks: [[Beat]] = []
        var current: [Beat] = []
        var currentWords = 0
        for b in sk.beats {
            let w = b.suggestedWords > 0 ? b.suggestedWords : perChunk / 2
            if !current.isEmpty, currentWords + w > perChunk {
                chunks.append(current); current = []; currentWords = 0
            }
            current.append(b); currentWords += w
        }
        if !current.isEmpty { chunks.append(current) }
        pipelineDone = []
        pipelineNote = ""

        var written = ""
        for (i, chunk) in chunks.enumerated() {
            pipelineStage = "写第 \(i + 1)/\(chunks.count) 段"
            let message = PromptLibrary.sceneDraftTask(
                chapter: n, title: store.chapter(n)?.title ?? "",
                beatIndex: i + 1, beatCount: chunks.count,
                beats: chunk, isLast: i == chunks.count - 1,
                endHook: sk.endHook, hookKind: sk.hookKind,
                mustDeliver: sk.mustDeliver, mustAvoid: sk.mustAvoid,
                clueTouches: sk.clueTouches, mainline: mainline,
                targetWords: max(400, chunk.reduce(0) { $0 + $1.suggestedWords }),
                pack: pack, previousText: written, model: config.model)
            guard let piece = await runTextOnly(store: store, config: config,
                                                capability: .chapterDraft, userMessage: message) else {
                pipelineStage = ""
                if lastError == nil { lastError = "第 \(i + 1) 段没有产出，已中止（前 \(i) 段未保存）。" }
                return
            }
            let cleaned = Self.stripProsePreamble(piece)
            guard !cleaned.isEmpty else {
                pipelineStage = ""
                lastError = "第 \(i + 1) 段返回的是空的，已中止。"
                return
            }
            written += (written.isEmpty ? "" : "\n\n") + cleaned
            pipelineDone.append("第\(i + 1)段 \(WordStats.chineseCount(cleaned))字")
        }
        pipelineStage = ""

        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = store.nextDraftVersion(for: n)
        let before = store.proposals.count
        await store.addProposal(AIProposal(
            capability: .chapterDraft, chapterNumber: n,
            title: "第\(n)章 草稿 v\(version)（分段写作 \(chunks.count) 段·\(WordStats.chineseCount(text)) 字）",
            note: "按骨架节拍分 \(chunks.count) 段续写后拼装：\(pipelineDone.joined(separator: "、"))。采纳前不进正文。",
            payload: .draft(ChapterDraft(chapter: n, text: text, version: version, mainline: mainline))))
        lastRunNewProposals = max(0, store.proposals.count - before)
        pipelineNote = "分段草稿 v\(version) 已进收件箱（\(WordStats.chineseCount(text)) 字，\(chunks.count) 段）。接着可以跑一致性审查与去AI味。"
    }

    /// 剥掉模型爱加的非正文外壳：围栏、"第N章"标题行、"以下是…"之类的开场白。
    /// 分块拼装时这些壳会夹在正文中间，不剥掉就毁了整章。
    static func stripProsePreamble(_ raw: String) -> String {
        // 围栏不一定在开头（"以下是这一段：\n```markdown\n正文\n```" 是模型的常见排法），
        // 所以先按行删掉所有独立的围栏行，再剥开场白——顺序反了就剥不干净。
        var lines = raw.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("```") && t.count <= 20)
        }
        var t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        lines = t.components(separatedBy: .newlines)
        let noisePrefixes = ["以下是", "下面是", "好的，", "好的,", "本章", "这一段", "续写", "第", "【", "（"]
        while let first = lines.first?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty, lines.count > 1,
              noisePrefixes.contains(where: { first.hasPrefix($0) }),
              first.count <= 30, !first.hasSuffix("。"), !first.hasSuffix("！”"), !first.hasSuffix("”") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runRevision(store: ProjectStore, config: AgentConfig, chapter n: Int, feedback: String) async {
        guard let proposal = store.latestDraftProposal(for: n),
              var draft = store.draftPayload(of: proposal) else {
            lastError = "还没有可修订的草稿——先在流水线里写一版。"
            return
        }
        draft.feedbackHistory.append(DraftFeedback(feedback: feedback, fromVersion: draft.version))
        let historyText = draft.feedbackHistory.map { "v\($0.fromVersion) 意见：\($0.feedback)" }.joined(separator: "\n")
        let message = PromptLibrary.revisionTask(
            chapter: n, draftText: draft.text, feedback: feedback,
            historyText: historyText, targetWords: store.project.chapterWordTarget,
            styleNotes: store.project.styleNotes)
        await run(capability: .chapterRevise, store: store, config: config, chapter: n, userMessage: message)
    }

    func runRecall(store: ProjectStore, config: AgentConfig, chapter n: Int, directive: String) async {
        let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: config.contextTokenBudget)
        // 一键召回：先把包本身登记为提案（作者可直接阅读），再让 AI 出备忘
        await store.addProposal(AIProposal(
            capability: .recallMemo, chapterNumber: n,
            title: "第\(n)章 上下文召回包（≈\(pack.approxTokens) tokens）",
            note: "确定性组装：热层前章结尾 + 近章摘要 + 贯穿线 + 活跃伏笔 + 角色状态 + 时间线锚点。",
            payload: .memo(pack.asText)))
        await run(capability: .recallMemo, store: store, config: config, chapter: n,
                  userMessage: PromptLibrary.recallMemoTask(chapter: n, pack: pack, authorDirective: directive))
    }
}

// MARK: - 无工具调用时的围栏 JSON 回退

enum FallbackProposer {
    struct Fallback: Decodable {
        let tool: String
        let args: JSONValue
    }

    static func parse(_ text: String) -> Fallback? {
        guard let start = text.range(of: "```json"), let end = text.range(of: "```", range: start.upperBound..<text.endIndex) else { return nil }
        let json = String(text[start.upperBound..<end.lowerBound])
        guard let data = json.data(using: .utf8),
              let fb = try? JSONDecoder().decode(Fallback.self, from: data) else { return nil }
        return fb
    }

    static func apply(_ fb: Fallback, store: ProjectStore, chapter: Int?) async throws {
        let jsonString = fb.args.jsonString
        let bound = NovelTools.bindChapter(tools: NovelTools.all(store: store), store: store, chapter: chapter)
        guard let tool = bound.first(where: { $0.name == fb.tool }) else {
            throw AgentError.badResponse("回退解析得到未知工具 \(fb.tool)")
        }
        _ = try await tool.handler(jsonString)
    }
}

/// 宽松 JSON 值（回退解析用）
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .null
    }

    var jsonString: String {
        // 用 JSONSerialization 序列化，字符串自动转义（引号/反斜杠/换行）
        func encode(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let str = String(data: data, encoding: .utf8) else { return "null" }
            return str
        }
        switch self {
        case .string(let s): return encode(s)
        case .number(let d):
            if d == d.rounded(), d >= Double(Int.min), d <= Double(Int.max) { return String(Int(d)) }
            return String(d)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .object(let o): return encode(Dictionary(uniqueKeysWithValues: o.map { ($0.key, $0.value.anyValue) }))
        case .array(let a): return encode(a.map(\.anyValue))
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .object(let o): return Dictionary(uniqueKeysWithValues: o.map { ($0.key, $0.value.anyValue) })
        case .array(let a): return a.map(\.anyValue)
        }
    }
}
