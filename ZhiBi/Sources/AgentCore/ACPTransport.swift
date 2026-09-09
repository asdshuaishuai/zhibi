import Foundation

/// 以 ACP 客户端身份连接 fx：spawn `fx acp` 子进程，
/// newline 分隔的 JSON-RPC 2.0 over stdio。
/// 必须先 `initialize`（fx 回应 protocolVersion 1），再 `session/new` / `session/prompt`。
/// 注意：ACP 模式下 fx 侧的 agent 自带工具体系，宿主的 propose 工具不参与；
/// 因此本传输不产生 toolCalls 事件，产出靠围栏 JSON 文本由上层解析（实验性）。
final class ACPTransport: AgentTransport {
    let kind = "fx ACP"
    private let executablePath: String
    private var process: Process?
    private var stdin: FileHandle?
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var chunkBuffer: String = ""
    private let queue = DispatchQueue(label: "com.zhibi.acp")
    private var lineBuffer: String = ""
    private(set) var sessionID: String?

    /// 在 queue 上消费一个网络分块，返回完整行与残余
    private func consumeChunk(_ text: String) -> ([String], String) {
        lineBuffer += text
        var parts = lineBuffer.components(separatedBy: "\n")
        guard parts.count > 1 else { return ([], lineBuffer) }
        let remainder = parts.removeLast()
        let lines = parts
        lineBuffer = remainder
        return (lines, remainder)
    }

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    deinit { shutdown() }

    func shutdown() {
        queue.sync {
            struct Cancelled: LocalizedError { var errorDescription: String? { "ACP 连接已关闭" } }
            for c in pending.values { c.resume(throwing: Cancelled()) }
            pending.removeAll()
        }
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    private func ensureLaunched() throws {
        guard process?.isRunning != true else { return }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw AgentError.transport("找不到 fx 可执行文件（\(executablePath)）。请先安装 fx 并在设置中填写路径。")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.arguments = ["acp"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        // stderr 不消费会撑爆 64KB 管道缓冲，子进程整体冻结
        errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting

        var lineBuffer = ""
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            lineBuffer += text
            var lines = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > 1 else { return }
            lineBuffer = String(lines.removeLast())
            for line in lines where !line.isEmpty {
                self?.handleLine(String(line))
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if let id = obj["id"] as? Int, let cont = self.pending.removeValue(forKey: id) {
                if let err = obj["error"] as? [String: Any] {
                    cont.resume(throwing: AgentError.transport("ACP 错误：\(err["message"] as? String ?? "未知")"))
                } else {
                    cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
                }
                return
            }
            if obj["method"] as? String == "session/update",
               let params = obj["params"] as? [String: Any],
               let update = params["update"] as? [String: Any],
               update["sessionUpdate"] as? String == "agent_message_chunk",
               let content = update["content"] as? [String: Any],
               let text = content["text"] as? String {
                self.chunkBuffer += text
            }
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        try ensureLaunched()
        // id 分配 + continuation 注册必须在写入 stdin 之前同块完成，否则秒回应答会被丢弃 → 永久挂起
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                queue.sync {
                    nextRequestID += 1
                    let id = nextRequestID
                    pending[id] = cont
                    do {
                        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                        try stdin?.write(contentsOf: data)
                        try stdin?.write(contentsOf: Data([0x0A]))
                    } catch {
                        pending.removeValue(forKey: id)
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            queue.async {
                struct Cancelled: LocalizedError { var errorDescription: String? { "请求已取消" } }
                for c in self.pending.values { c.resume(throwing: Cancelled()) }
                self.pending.removeAll()
            }
        }
    }

    func complete(messages: [FxMessage], tools: [AgentTool]) -> AsyncThrowingStream<FxTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if sessionID == nil {
                        _ = try await request(method: "initialize", params: [:])
                        let sess = try await request(method: "session/new", params: [:])
                        sessionID = sess["sessionId"] as? String
                    }
                    let text = messages.filter { $0.role != "system" }.compactMap(\.content).joined(separator: "\n\n")
                    let promptParams: [String: Any] = [
                        "sessionId": sessionID ?? "",
                        "prompt": [["type": "text", "text": text]],
                    ]
                    queue.async { self.chunkBuffer = "" }
                    _ = try await request(method: "session/prompt", params: promptParams)
                    let buffered = queue.sync { self.chunkBuffer }
                    if !buffered.isEmpty {
                        continuation.yield(.textDelta(buffered))
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
}
