import Foundation

// MARK: - fx (libfx) 模型的 Swift 同构
//
// fx 文档模型：one agent is one in-memory conversation；
// prompt() 返回 Turn（事件异步流）；checkpoint 保存对话状态（宿主负责持久化）；
// 指令 / 工具 / 凭据全部由宿主应用提供。

struct FxMessage: Codable {
    var role: String                 // system / user / assistant / tool
    var content: String?
    var toolCalls: [FxToolCall]?
    var toolCallID: String?
    var toolName: String?

    static func system(_ s: String) -> FxMessage { FxMessage(role: "system", content: s) }
    static func user(_ s: String) -> FxMessage { FxMessage(role: "user", content: s) }
}

struct FxToolCall: Codable {
    var id: String
    var name: String
    var arguments: String            // JSON 字符串
}

enum FxTransportEvent {
    case textDelta(String)
    case toolCalls([FxToolCall])
    case finish
}

/// 宿主提供的工具。handler 的返回值会作为 tool 消息回给模型；抛错则以错误文本回灌。
struct AgentTool {
    let name: String
    let description: String
    let parametersJSON: String       // JSON Schema
    let handler: (_ argsJSON: String) async throws -> String
}

/// Turn 事件（对外观测）
enum FxEvent {
    case textDelta(String)
    case toolCall(FxToolCall, result: String)
    case finished(fullText: String)
}

/// 一个 Agent = 一段内存会话（fx 模型同构）
final class FxAgent {
    private(set) var messages: [FxMessage] = []
    private let transport: AgentTransport
    private(set) var instruction: String

    init(transport: AgentTransport, instruction: String) {
        self.transport = transport
        self.instruction = instruction
    }

    func setInstruction(_ s: String) {
        instruction = s
        if let idx = messages.firstIndex(where: { $0.role == "system" }) {
            messages[idx].content = s
        }
    }

    /// fx: agent.prompt(text) -> Turn
    /// 宿主侧跑工具循环：模型发起 tool_call → 宿主执行 → 结果回灌 → 直到 finish 或达到轮数上限。
    func prompt(_ text: String, tools: [AgentTool], maxToolRounds: Int = 6) -> AsyncThrowingStream<FxEvent, Error> {
        if messages.first(where: { $0.role == "system" }) == nil {
            messages.insert(FxMessage.system(instruction), at: 0)
        }
        messages.append(FxMessage.user(text))

        return AsyncThrowingStream { continuation in
            let task = Task {
                var fullText = ""
                var rounds = 0
                do {
                    var sawToolCalls = false
                    while true {
                        var roundText = ""
                        var pendingToolCalls: [FxToolCall] = []
                        for try await event in transport.complete(messages: messages, tools: tools) {
                            switch event {
                            case .textDelta(let d):
                                roundText += d
                                fullText += d
                                continuation.yield(.textDelta(d))
                            case .toolCalls(let calls):
                                pendingToolCalls = calls
                            case .finish:
                                break
                            }
                        }
                        if pendingToolCalls.isEmpty || rounds >= maxToolRounds {
                            break
                        }
                        rounds += 1
                        sawToolCalls = true
                        messages.append(FxMessage(role: "assistant", content: roundText.isEmpty ? nil : roundText, toolCalls: pendingToolCalls))
                        for call in pendingToolCalls {
                            let tool = tools.first { $0.name == call.name }
                            let result: String
                            if let tool {
                                do {
                                    result = try await tool.handler(call.arguments)
                                } catch {
                                    result = "工具执行失败：\(error.localizedDescription)"
                                }
                            } else {
                                result = "未知工具：\(call.name)"
                            }
                            continuation.yield(.toolCall(call, result: result))
                            messages.append(FxMessage(role: "tool", content: result, toolCallID: call.id, toolName: call.name))
                        }
                    }
                    if !sawToolCalls {
                        messages.append(FxMessage(role: "assistant", content: fullText))
                    }
                    continuation.yield(.finished(fullText: fullText))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// fx: checkpoint() —— 序列化会话状态，宿主负责持久化
    func checkpoint() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        return (try? enc.encode(messages)) ?? Data()
    }

    /// 恢复 checkpoint
    func restore(_ data: Data) {
        let dec = JSONDecoder()
        if let restored = try? dec.decode([FxMessage].self, from: data) {
            messages = restored
            if messages.first(where: { $0.role == "system" }) == nil {
                messages.insert(FxMessage.system(instruction), at: 0)
            }
        }
    }

    /// fx: close()
    func close() {
        messages.removeAll()
    }
}
