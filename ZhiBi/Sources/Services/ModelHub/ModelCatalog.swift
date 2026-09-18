import Foundation

// MARK: - ModelHub · 模型集成模块
//
// 数据源：models.dev 开放目录（https://models.dev，GitHub sst/models）。
// 架构参考 Vercel AI SDK（https://ai-sdk.dev）的 provider 抽象：
// 供应商 = 端点 + 鉴权 + 模型集；模型 = ID + 能力声明（工具/推理/结构化输出）+
// 上下文与价格。本模块做三件事：解析目录、拉取并缓存、把「供应商+模型」
// 选择解析成 OpenAI 兼容的 (baseURL, model) 二元组供 Agent 基座使用。

enum ModelHub {

    /// 内置关注供应商：目录里拉到即展示（中/英区、编程计划各算一条）
    static let featuredProviderIDs: [String] = [
        "deepseek", "zhipuai", "zhipuai-coding-plan", "moonshotai-cn", "moonshotai",
        "minimax-cn", "minimax", "agnes", "longcat", "openai", "openrouter",
        "siliconflow-cn", "qiniu-ai", "ollama-cloud",
    ]

    /// 目录端点不是 OpenAI 兼容的供应商：按官方文档改写为 OpenAI 兼容端点。
    /// （MiniMax 目录只登记 Anthropic 端点；OpenAI 兼容端点为 /v1。）
    private static let openAIEndpointOverrides: [String: String] = [
        "minimax": "https://api.minimax.io/v1",
        "minimax-cn": "https://api.minimaxi.com/v1",
        "minimax-coding-plan": "https://api.minimax.io/v1",
        "minimax-cn-coding-plan": "https://api.minimaxi.com/v1",
    ]

    /// 手工兜底条目（目录拉不到且无缓存时的离线选择）
    static let offlineFallbacks: [Entry] = [
        Entry(providerID: "deepseek", providerName: "DeepSeek", baseURL: "https://api.deepseek.com",
              modelID: "deepseek-flash", modelName: "DeepSeek V4 Flash", toolCall: true, reasoning: true,
              contextLimit: nil, inputCost: nil, outputCost: nil),
        Entry(providerID: "zhipuai", providerName: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4",
              modelID: "glm-5.3", modelName: "GLM-5.3", toolCall: true, reasoning: true,
              contextLimit: nil, inputCost: nil, outputCost: nil),
        Entry(providerID: "zhipuai-coding-plan", providerName: "GLM 编程计划", baseURL: "https://open.bigmodel.cn/api/coding/paas/v4",
              modelID: "glm-5.3", modelName: "GLM-5.3", toolCall: true, reasoning: true,
              contextLimit: nil, inputCost: nil, outputCost: nil),
        Entry(providerID: "minimax-cn", providerName: "MiniMax", baseURL: "https://api.minimaxi.com/v1",
              modelID: "MiniMax-M2.7-highspeed", modelName: "MiniMax M2.7 Highspeed", toolCall: true, reasoning: true,
              contextLimit: nil, inputCost: nil, outputCost: nil),
        Entry(providerID: "openai", providerName: "OpenAI", baseURL: "https://api.openai.com/v1",
              modelID: "gpt-5.2-chat-latest", modelName: "GPT-5.2 Chat", toolCall: true, reasoning: true,
              contextLimit: nil, inputCost: nil, outputCost: nil),
    ]

    // MARK: - 目录数据模型

    struct Provider: Identifiable, Equatable {
        let id: String
        let name: String
        /// OpenAI 兼容端点（已做协议修正）
        let baseURL: String
        let envVars: [String]
        let docURL: String?

        static func == (lhs: Provider, rhs: Provider) -> Bool { lhs.id == rhs.id && lhs.baseURL == rhs.baseURL }

        let models: [Model]

        /// 参与排序：内置关注供应商优先，其余按名称
        var sortKey: Int { featuredProviderIDs.firstIndex(of: id) ?? featuredProviderIDs.count }
    }

    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        let toolCall: Bool
        let reasoning: Bool
        let structuredOutput: Bool
        let contextLimit: Int?
        let inputCost: Double?     // 每百万 tokens，美元
        let outputCost: Double?
        let description: String?

        var capabilitySummary: String {
            var parts: [String] = []
            parts.append(toolCall ? "工具 ✓" : "工具 ✗")
            if reasoning { parts.append("推理 ✓") }
            if structuredOutput { parts.append("结构化 ✓") }
            if let contextLimit { parts.append("上下文 \(Self.shortCount(contextLimit))") }
            if let inputCost, let outputCost {
                parts.append(String(format: "$%.2f/$%.2f 每百万", inputCost, outputCost))
            }
            return parts.joined(separator: " · ")
        }

        static func shortCount(_ n: Int) -> String {
            switch n {
            case 1_000_000...: return "\(n / 1_000_000)M"
            case 1_000...: return "\(n / 1_000)K"
            default: return "\(n)"
            }
        }
    }

    /// 一条可选的「供应商 + 模型」，选择器与配置解析的最小单元
    struct Entry: Identifiable, Equatable {
        var id: String { providerID + "/" + modelID }
        let providerID: String
        let providerName: String
        let baseURL: String
        let modelID: String
        let modelName: String
        let toolCall: Bool
        let reasoning: Bool
        let contextLimit: Int?
        let inputCost: Double?
        let outputCost: Double?
    }

    // MARK: - 解析（ai-sdk 风格：provider = 端点 + 模型集）

    static func parseCatalog(_ data: Data) -> [Provider] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var providers: [Provider] = []
        for (pid, pv) in raw {
            guard let pv = pv as? [String: Any],
                  let modelsRaw = pv["models"] as? [String: Any], !modelsRaw.isEmpty else { continue }
            let name = (pv["name"] as? String) ?? pid
            let npm = (pv["npm"] as? String) ?? ""
            var endpoint = pv["api"] as? String
            if endpoint == nil || npm.contains("anthropic") {
                // Anthropic 协议目录条目：只收录有 OpenAI 端点改写的（minimax 系）
                guard let overridden = openAIEndpointOverrides[pid] else { continue }
                endpoint = overridden
            }
            guard var baseURL = endpoint else { continue }
            while baseURL.hasSuffix("/") { baseURL.removeLast() }

            var models: [Model] = []
            for (mid, mv) in modelsRaw {
                guard let mv = mv as? [String: Any] else { continue }
                let limit = mv["limit"] as? [String: Any]
                let cost = mv["cost"] as? [String: Any]
                models.append(Model(
                    id: (mv["id"] as? String) ?? mid,
                    name: (mv["name"] as? String) ?? mid,
                    toolCall: (mv["tool_call"] as? Bool) ?? false,
                    reasoning: (mv["reasoning"] as? Bool) ?? false,
                    structuredOutput: (mv["structured_output"] as? Bool) ?? false,
                    contextLimit: limit?["context"] as? Int,
                    inputCost: cost?["input"] as? Double,
                    outputCost: cost?["output"] as? Double,
                    description: mv["description"] as? String))
            }
            // 工具调用优先，同档按名称
            models.sort { lhs, rhs in
                if lhs.toolCall != rhs.toolCall { return lhs.toolCall }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            guard !models.isEmpty else { continue }
            providers.append(Provider(
                id: pid, name: name, baseURL: baseURL,
                envVars: (pv["env"] as? [String]) ?? [],
                docURL: pv["doc"] as? String, models: models))
        }
        return providers.sorted { lhs, rhs in
            if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 目录 + 兜底合并为可选条目（默认只展示支持工具调用的模型——工具循环是硬依赖）
    static func entries(from providers: [Provider], toolCallOnly: Bool = true) -> [Entry] {
        var out: [Entry] = []
        for p in providers {
            for m in p.models where !toolCallOnly || m.toolCall {
                out.append(Entry(providerID: p.id, providerName: p.name, baseURL: p.baseURL,
                                 modelID: m.id, modelName: m.name,
                                 toolCall: m.toolCall, reasoning: m.reasoning,
                                 contextLimit: m.contextLimit,
                                 inputCost: m.inputCost, outputCost: m.outputCost))
            }
        }
        return out
    }

    // MARK: - 拉取与缓存

    static let remoteURL = URL(string: "https://models.dev/api.json")!
    /// 缓存有效期（目录每天更新足够）
    static let cacheTTL: TimeInterval = 24 * 3600

    static func cacheURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhiBi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model-catalog.json")
    }

    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded(date: Date, source: Source)
        case failed(message: String)
    }

    enum Source: Equatable {
        case network
        case cache
    }

    /// 拉取目录：先用缓存（未过期则直接返回），再后台刷新网络版本
    static func loadCatalog(forceRefresh: Bool = false) async -> (providers: [Provider], state: CatalogState) {
        let cache = cacheURL()
        let attrs = (try? FileManager.default.attributesOfItem(atPath: cache.path))
        let fresh = (attrs?[.modificationDate] as? Date)
        if !forceRefresh, let fresh, Date().timeIntervalSince(fresh) < cacheTTL,
           let data = try? Data(contentsOf: cache) {
            let providers = parseCatalog(data)
            if !providers.isEmpty {
                return (providers, .loaded(date: fresh, source: .cache))
            }
        }
        do {
            var req = URLRequest(url: remoteURL)
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw AgentError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let providers = parseCatalog(data)
            guard !providers.isEmpty else { throw AgentError.badResponse("目录解析为空") }
            try? data.write(to: cache, options: .atomic)
            return (providers, .loaded(date: Date(), source: .network))
        } catch {
            // 网络失败：退回过期缓存或离线兜底
            if let data = try? Data(contentsOf: cache) {
                let providers = parseCatalog(data)
                if !providers.isEmpty {
                    return (providers, .loaded(date: fresh ?? Date(), source: .cache))
                }
            }
            return ([], .failed(message: error.localizedDescription))
        }
    }
}
