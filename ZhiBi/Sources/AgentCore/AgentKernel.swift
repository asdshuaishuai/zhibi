import Foundation
import OpenAgentSDK

// MARK: - Agent 内核公共类型（基座：OpenAgentSDK，terryso/open-agent-sdk-swift）
//
// 职责划分：OpenAgentSDK 负责 agent 循环、流式与供应商传输（OpenAI 兼容，
// DeepSeek / MiniMax / GLM / Kimi / Ollama 换 baseURL 即换）；本文件只保留
// 执笔自己的三样东西：提案工具描述、错误类型、MiniMax 思考内容展示过滤。

/// 宿主提供的工具。handler 的返回值会作为 tool 消息回给模型；抛错则以错误文本回灌。
struct AgentTool {
    let name: String
    let description: String
    let parametersJSON: String       // JSON Schema
    let handler: (_ argsJSON: String) async throws -> String
}

enum AgentError: LocalizedError {
    case noAPIKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "未配置 API Key。请在 设置 里填写（保存在 macOS 钥匙串）。"
        case .badResponse(let s): return "响应无法解析：\(s)"
        }
    }
}

// MARK: - 流式 <think>…</think> 过滤
//
// MiniMax 系列默认把思考内容以 <think>…</think> 内嵌在正文增量里（未开 reasoning_split），
// 展示层（运行预览/文本提案回退）不应露出思考原文。标记可能被增量切开，需跨段持有半个尾巴。

struct ThinkTagFilter {
    private var buffer = ""
    private var hiding = false

    /// 喂入一段增量，返回其中可直接展示的部分
    mutating func push(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        buffer += delta
        var out = ""
        while true {
            if hiding {
                if let end = buffer.range(of: "</think>") {
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    hiding = false
                    continue
                }
                // 结束标记未到齐：整段丢弃，只留可能是 "</think>" 前缀的尾巴
                buffer = Self.partialSuffix(of: buffer, matching: "</think>")
                break
            } else {
                if let start = buffer.range(of: "<think>") {
                    out += String(buffer[buffer.startIndex..<start.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<start.upperBound)
                    hiding = true
                    continue
                }
                let hold = Self.partialSuffix(of: buffer, matching: "<think>")
                out += String(buffer.dropLast(hold.count))
                buffer = hold
                break
            }
        }
        return out
    }

    /// 流结束：未闭合的思考块视为思考内容整体丢弃
    mutating func flush() -> String {
        defer { buffer = "" }
        return hiding ? "" : buffer
    }

    /// buffer 末尾与 tag 前缀的最长重叠（k 个尾字符恰是 tag 的前 k 个字符）
    private static func partialSuffix(of s: String, matching tag: String) -> String {
        let maxLen = min(s.count, tag.count - 1)
        guard maxLen > 0 else { return "" }
        for k in stride(from: maxLen, through: 1, by: -1) {
            let tail = String(s.suffix(k))
            if tag.hasPrefix(tail) { return tail }
        }
        return ""
    }
}

// MARK: - 提案工具 → OpenAgentSDK 桥接

enum ProposalToolBridge {
    /// 把执笔的提案工具桥接为 SDK 工具。入参走原始字典重载：
    /// 序列化回 JSON 字符串后交给原有容错解析，模型产出的不规范 JSON 仍可修复。
    static func sdkTools(_ tools: [AgentTool]) -> [ToolProtocol] {
        tools.map { tool in
            let schema = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any]
                ?? ["type": "object", "properties": [:] as [String: Any]]
            return defineTool(
                name: tool.name,
                description: tool.description,
                inputSchema: schema,
                isReadOnly: true   // 提案只登记待审批条目，不直接改盘
            ) { args, _ in
                do {
                    let data = try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])
                    let result = try await tool.handler(String(decoding: data, as: UTF8.self))
                    return ToolExecuteResult(content: result, isError: false)
                } catch {
                    return ToolExecuteResult(content: "工具执行失败：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }
}
