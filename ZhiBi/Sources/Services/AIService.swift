import Foundation

/// AI 任务编排器。所有能力都走同一通道：
/// 造包 → 组 prompt → FxAgent.prompt（工具循环）→ 提案落收件箱。
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

    func makeTransport(config: AgentConfig) throws -> AgentTransport {
        switch config.transport {
        case .openAICompatible:
            guard !config.apiKey.isEmpty || config.baseURL.contains("localhost") || config.baseURL.contains("127.0.0.1") else {
                throw AgentError.noAPIKey
            }
            return OpenAICompatibleTransport(config: OpenAIConfig(
                baseURL: config.baseURL, apiKey: config.apiKey,
                model: config.model, temperature: config.temperature))
        case .acp:
            return ACPTransport(executablePath: config.acpExecutablePath)
        }
    }

    /// 任务 → 该能力可用的工具子集
    private func tools(for capability: AICapability, store: ProjectStore, chapter: Int?) -> [AgentTool] {
        let all = NovelTools.all(store: store)
        let needed: Set<String>
        switch capability {
        case .outlineTimeline:
            needed = ["propose_storylines", "propose_outline_events", "get_outline", "get_canon"]
        case .clueLedger:
            needed = ["propose_clues", "get_clues", "get_outline", "get_chapter"]
        case .chapterSkeleton:
            needed = ["propose_skeleton", "propose_clues", "get_clues", "get_outline", "get_facts"]
        case .chapterDraft:
            needed = ["propose_draft", "get_clues", "get_canon", "get_facts", "get_outline"]
        case .chapterRevise:
            needed = ["propose_draft"]
        case .memoryExtract:
            needed = ["propose_memory", "propose_clues", "get_clues", "get_facts"]
        case .validation:
            needed = ["propose_validation", "get_chapter", "get_clues", "get_facts", "get_canon", "get_outline"]
        case .deslop:
            needed = ["propose_deslop"]
        case .recallMemo:
            needed = ["propose_memo"]
        }
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
            let transport = try makeTransport(config: config)
            let fx = FxAgent(transport: transport, instruction: PromptLibrary.systemInstruction(for: capability))
            let toolset = tools(for: capability, store: store, chapter: chapter)
            let proposalsBefore = store.proposals.count

            for try await event in fx.prompt(userMessage, tools: toolset) {
                switch event {
                case .textDelta(let d):
                    streamPreview += d
                    if streamPreview.count > 4000 { streamPreview = String(streamPreview.suffix(4000)) }
                case .toolCall(let call, let result):
                    lastToolLog.append("🛠 \(call.name) → \(String(result.prefix(120)))")
                case .finished:
                    break
                }
            }

            // 兜底：若模型没用工具（如 ACP 模式），解析围栏 JSON 并代为登记提案
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

            // checkpoint 持久化（fx：宿主负责存储）
            if capability == .outlineTimeline {
                store.saveCheckpoint(fx.checkpoint(), name: "outline-session.json")
            }
            fx.close()
            lastRunNewProposals = max(0, store.proposals.count - proposalsBefore)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 具体能力入口

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
        await run(capability: .chapterSkeleton, store: store, config: config, chapter: n,
                  userMessage: PromptLibrary.chapterSkeletonTask(chapter: n, chapterTitle: title, pack: pack, authorDirective: directive))
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
        // 先验证传输可用（Key 等），避免确定性报告先落库成永不合并的孤儿
        _ = (try? makeTransport(config: config))?.kind
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
        var report = Validator.deterministicReport(store: store, chapter: n)
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

    func runDraft(store: ProjectStore, config: AgentConfig, chapter n: Int, mainline: String) async {
        let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: config.contextTokenBudget)
        var skeletonText = ""
        if let sk = store.chapter(n)?.skeleton, !sk.beats.isEmpty {
            skeletonText = sk.beats.enumerated().map { i, b in
                "\(i + 1). \(b.summary)（\(b.purpose)\(b.suggestedWords > 0 ? "｜约\(b.suggestedWords)字" : "")）"
            }.joined(separator: "\n")
            if !sk.endHook.isEmpty { skeletonText += "\n章尾钩子：\(sk.endHook)" }
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
