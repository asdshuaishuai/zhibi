import Foundation

/// OpenAI 兼容的 /embeddings 客户端。
/// 只在作者配置了 `embeddingModel` 时启用；任何失败都返回 nil，由资料库回退到本地哈希向量，
/// 不让“没有向量模型”变成聊天/检索不可用。
///
/// 远程嵌入按「端点 + 模型 + 原文」缓存：资料库每次检索都会重排同一批片段，
/// 不缓存就会每问一次都把整批正文重新发一遍，既慢又费额度。
enum EmbeddingService {
    @MainActor private static var cache: [String: [Float]] = [:]
    @MainActor private static var cacheOrder: [String] = []
    private static let cacheLimit = 2048

    @MainActor
    static func embed(texts: [String], config: AgentConfig) async -> [[Float]]? {
        let model = (config.embeddingModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !texts.isEmpty else { return nil }
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }

        var missing: [String] = []
        var seen = Set<String>()
        for text in texts {
            let key = cacheKey(base: base, model: model, text: text)
            if cache[key] == nil, seen.insert(key).inserted { missing.append(text) }
        }
        if !missing.isEmpty {
            guard let fresh = await requestEmbeddings(texts: missing, base: base,
                                                      model: model, config: config),
                  fresh.count == missing.count else { return nil }
            for (i, text) in missing.enumerated() {
                store(cacheKey(base: base, model: model, text: text), fresh[i])
            }
        }

        let keys = texts.map { cacheKey(base: base, model: model, text: $0) }
        guard keys.allSatisfy({ cache[$0] != nil }) else { return nil }
        return keys.compactMap { cache[$0] }
    }

    /// 仅供自检/诊断：当前进程里缓存了多少条远程向量。
    @MainActor static func cachedCount() -> Int { cache.count }

    @MainActor static func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - 内部

    @MainActor
    private static func cacheKey(base: String, model: String, text: String) -> String {
        base + "|" + model + "|" + text
    }

    @MainActor
    private static func store(_ key: String, _ vector: [Float]) {
        if cache[key] == nil {
            cacheOrder.append(key)
            while cacheOrder.count > cacheLimit {
                let old = cacheOrder.removeFirst()
                cache.removeValue(forKey: old)
            }
        }
        cache[key] = vector
    }

    /// 单次请求的输入条数上限：不同兼容端点的输入上限差异很大，分批最稳。
    private static let batchSize = 16

    @MainActor
    private static func requestEmbeddings(texts: [String], base: String,
                                          model: String, config: AgentConfig) async -> [[Float]]? {
        var out: [[Float]] = []
        var offset = 0
        while offset < texts.count {
            let end = min(offset + batchSize, texts.count)
            let batch = Array(texts[offset..<end])
            guard let vectors = await requestBatch(texts: batch, base: base,
                                                   model: model, config: config),
                  vectors.count == batch.count else { return nil }
            out.append(contentsOf: vectors)
            offset = end
        }
        return out
    }

    @MainActor
    private static func requestBatch(texts: [String], base: String,
                                     model: String, config: AgentConfig) async -> [[Float]]? {
        var candidates = [base]
        if !base.hasSuffix("/v1") { candidates.append(base + "/v1") }
        for candidate in candidates {
            let clean = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
            guard let url = URL(string: clean + "/embeddings") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 8
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = AIService.effectiveKey(config), !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let body: [String: Any] = ["model": model, "input": texts]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { continue }
            req.httpBody = data
            do {
                let (respData, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else { continue }
                // OpenAI 规范：data[i].index 指明它对应 input 的第几条。不能假设返回顺序。
                if let arr = obj["data"] as? [[String: Any]] {
                    var byIndex: [Int: [Float]] = [:]
                    for (pos, item) in arr.enumerated() {
                        guard let e = item["embedding"] as? [Double] else { continue }
                        let idx = item["index"] as? Int ?? pos
                        byIndex[idx] = e.map(Float.init)
                    }
                    if texts.indices.allSatisfy({ byIndex[$0] != nil }) {
                        return texts.indices.map { byIndex[$0]! }
                    }
                }
                // 少数兼容端点只返回 embeddings 数组，按顺序对应 input。
                if let arr = obj["embeddings"] as? [[Double]], arr.count == texts.count {
                    return arr.map { $0.map(Float.init) }
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
