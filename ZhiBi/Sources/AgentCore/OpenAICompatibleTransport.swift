import Foundation

protocol AgentTransport {
    var kind: String { get }
    func complete(messages: [FxMessage], tools: [AgentTool]) -> AsyncThrowingStream<FxTransportEvent, Error>
}

// MARK: - OpenAI 兼容传输（SSE 流式 + tool-calling 循环由 FxAgent 驱动）

struct OpenAIConfig {
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double
}

final class OpenAICompatibleTransport: AgentTransport {
    let kind = "OpenAI 兼容"
    private let config: OpenAIConfig

    init(config: OpenAIConfig) {
        self.config = config
    }

    private struct ToolCallAccumulator {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    func complete(messages: [FxMessage], tools: [AgentTool]) -> AsyncThrowingStream<FxTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try Self.requestBody(messages: messages, tools: tools, config: config)
                    let cleaned = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let endpoint = URL(string: cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
                        throw AgentError.transport("Base URL 无效：\(cleaned)")
                    }
                    // 远程 http 会明文传输 API Key；仅本地回环地址豁免
                    if endpoint.scheme?.lowercased() == "http",
                       !["localhost", "127.0.0.1", "::1"].contains(endpoint.host?.lowercased() ?? "") {
                        throw AgentError.transport("远程 API 地址不要用 http://（API Key 会明文出网），请改用 https://；本地 Ollama 不受限制。")
                    }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !config.apiKey.isEmpty {
                        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    req.httpBody = body

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw AgentError.transport("非 HTTP 响应")
                    }
                    guard http.statusCode == 200 else {
                        let errText = (try? await bytes.lines.reduce(into: "") { $0 += $1 }) ?? ""
                        throw AgentError.transport("API \(http.statusCode)：\(String(errText.prefix(500)))")
                    }

                    var accums: [Int: ToolCallAccumulator] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let choice = choices.first else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield(.textDelta(content))
                            }
                            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                for tc in tcs {
                                    let index = (tc["index"] as? Int) ?? 0
                                    var acc = accums[index] ?? ToolCallAccumulator()
                                    if let id = tc["id"] as? String, !id.isEmpty { acc.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
                                        if let args = fn["arguments"] as? String { acc.arguments += args }
                                    }
                                    accums[index] = acc
                                }
                            }
                        }
                    }
                    let calls = accums.keys.sorted().compactMap { idx -> FxToolCall? in
                        guard var acc = accums[idx], !acc.name.isEmpty else { return nil }
                        if acc.id.isEmpty { acc.id = "call_\(idx)" }
                        if acc.arguments.isEmpty { acc.arguments = "{}" }
                        return FxToolCall(id: acc.id, name: acc.name, arguments: acc.arguments)
                    }
                    if !calls.isEmpty {
                        continuation.yield(.toolCalls(calls))
                    }
                    continuation.yield(.finish)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func requestBody(messages: [FxMessage], tools: [AgentTool], config: OpenAIConfig) throws -> Data {
        var msgs: [[String: Any]] = []
        for m in messages {
            var obj: [String: Any] = ["role": m.role]
            if let c = m.content { obj["content"] = c }
            if let tcs = m.toolCalls {
                obj["tool_calls"] = tcs.map { tc in
                    ["id": tc.id, "type": "function",
                     "function": ["name": tc.name, "arguments": tc.arguments]]
                }
            }
            if let tid = m.toolCallID { obj["tool_call_id"] = tid }
            if m.role == "tool", let tn = m.toolName { obj["name"] = tn }
            msgs.append(obj)
        }
        var body: [String: Any] = [
            "model": config.model,
            "messages": msgs,
            "stream": true,
            "temperature": config.temperature,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                ["type": "function",
                 "function": ["name": t.name, "description": t.description] as [String: Any]]
            }
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

enum AgentError: LocalizedError {
    case transport(String)
    case noAPIKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .transport(let s): return "传输错误：\(s)"
        case .noAPIKey: return "未配置 API Key。请在 设置 里填写（保存在 macOS 钥匙串）。"
        case .badResponse(let s): return "响应无法解析：\(s)"
        }
    }
}
