import Foundation
import PiKit

/// 一个 MCP 工具的描述（来自服务器 `tools/list`）。
struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

/// MCP 客户端错误。
enum MCPError: Error, LocalizedError {
    case notRunning
    case processFailed(String)
    case invalidMessage(String)
    case rpc(code: Int, message: String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "MCP 服务器未运行"
        case .processFailed(let detail):
            return "MCP 服务器进程错误：\(detail)"
        case .invalidMessage(let detail):
            return "MCP 消息格式错误：\(detail)"
        case .rpc(let code, let message):
            return "MCP 服务器返回错误（\(code)）：\(message)"
        case .timeout(let method):
            return "MCP 请求超时：\(method)"
        }
    }
}

/// 通过 stdio 与单个 MCP 服务器通信的 JSON-RPC 2.0 客户端。
///
/// 协议采用以换行分隔的 JSON（每条消息一行）。子进程的 stdout 与 stderr 通过
/// `readabilityHandler` 异步读取，不阻塞也不占用线程，避免管道写满导致死锁；
/// 请求按 `id` 关联，每个请求默认 20 秒超时。实例可安全地从多个线程调用。
final class MCPClient: @unchecked Sendable {

    let server: String
    private let command: String
    private let args: [String]
    private let extraEnv: [String: String]
    private let timeout: TimeInterval

    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var nextID = 1
    private var continuations: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeoutItems: [Int: DispatchWorkItem] = [:]
    private var shuttingDown = false
    private var running = false

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let bufferLock = NSLock()
    private var lineBuffer = Data()

    init(server: String, command: String, args: [String] = [], env: [String: String] = [:], timeout: TimeInterval = 20) {
        self.server = server
        self.command = command
        self.args = args
        self.extraEnv = env
        self.timeout = timeout
    }

    // MARK: - 生命周期

    /// 启动子进程并完成 MCP 握手（initialize + notifications/initialized）。
    func start() async throws {
        try launch()

        let params: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Myna"),
                "version": .string("1.0"),
            ]),
        ])
        _ = try await send(method: "initialize", params: params)
        try sendNotification(method: "notifications/initialized", params: nil)
    }

    /// 拉取服务器工具列表。
    func listTools() async throws -> [MCPTool] {
        let result = try await send(method: "tools/list", params: .object([:]))
        guard let tools = result["tools"].arrayValue else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"].stringValue else { return nil }
            let description = tool["description"].stringValue ?? ""
            let schema: JSONValue = tool["inputSchema"].isNull
                ? .object(["type": .string("object"), "properties": .object([:])])
                : tool["inputSchema"]
            return MCPTool(name: name, description: description, inputSchema: schema)
        }
    }

    /// 调用工具并把 `content[].text` 拼接为字符串。
    func callTool(name: String, arguments: JSONValue) async throws -> String {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
        ])
        let result = try await send(method: "tools/call", params: params)

        var pieces: [String] = []
        if let content = result["content"].arrayValue {
            for block in content {
                if let text = block["text"].stringValue { pieces.append(text) }
            }
        }
        let isError = result["isError"].boolValue ?? false
        var text = pieces.joined()
        let structured = result["structuredContent"]
        if text.isEmpty, !structured.isNull,
           let data = try? JSONEncoder().encode(structured),
           let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        }
        if text.isEmpty { text = isError ? "（无错误详情）" : "（工具没有返回文本内容）" }
        return isError ? "MCP 工具错误：\(text)" : text
    }

    /// 关闭 stdin、终止子进程，并让所有未完成的请求失败。
    func shutdown() {
        stateLock.lock()
        shuttingDown = true
        let proc = process
        let handle = stdinHandle
        let out = stdoutHandle
        let err = stderrHandle
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        running = false
        stateLock.unlock()

        out?.readabilityHandler = nil
        err?.readabilityHandler = nil
        try? handle?.close()
        if let proc, proc.isRunning {
            let pid = proc.processIdentifier
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        failAllPending(MCPError.notRunning)
    }

    // MARK: - 启动子进程

    private func launch() throws {
        let proc = Process()
        // 统一经 /usr/bin/env 启动，使 npx / uvx 等依赖 PATH 的命令可用。
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + args

        var environment = ProcessInfo.processInfo.environment
        let basePath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePath
        for (key, value) in extraEnv { environment[key] = value }
        proc.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw MCPError.processFailed("无法启动「\(command)」：\(error.localizedDescription)")
        }

        // 关闭父进程侧不用的管道端，使子进程退出时能读到 EOF（否则父进程持有写端）。
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        stateLock.lock()
        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading
        running = true
        shuttingDown = false
        stateLock.unlock()

        // 用 readabilityHandler 而非阻塞式 read：后者在管道上可能等到 EOF 才返回。
        let name = server
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            MCPClient.consumeStderr(handle, server: name)
        }
    }

    // MARK: - 发送

    private func send(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = allocateID()
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params.foundationValue }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            stateLock.lock()
            if shuttingDown || !running {
                stateLock.unlock()
                continuation.resume(throwing: MCPError.notRunning)
                return
            }
            continuations[id] = continuation
            let item = DispatchWorkItem { [weak self] in
                self?.finish(id: id, result: .failure(MCPError.timeout(method)))
            }
            timeoutItems[id] = item
            stateLock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)

            do {
                try write(message)
            } catch {
                finish(id: id, result: .failure(error))
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue?) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params.foundationValue }
        try write(message)
    }

    private func allocateID() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let value = nextID
        nextID += 1
        return value
    }

    /// 向 stdin 写入一行 JSON。串行化写入，避免并发请求交错。
    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)

        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let handle = stdinHandle
        let alive = running && !shuttingDown
        stateLock.unlock()
        guard alive, let handle else { throw MCPError.notRunning }
        do {
            try handle.write(contentsOf: line)
        } catch {
            throw MCPError.processFailed(error.localizedDescription)
        }
    }

    /// 完成一个请求：取消超时并恢复对应的 continuation。仅第一次生效。
    private func finish(id: Int, result: Result<JSONValue, Error>) {
        stateLock.lock()
        guard let continuation = continuations.removeValue(forKey: id) else {
            stateLock.unlock()
            return
        }
        let item = timeoutItems.removeValue(forKey: id)
        stateLock.unlock()
        item?.cancel()
        continuation.resume(with: result)
    }

    private func failAllPending(_ error: Error) {
        stateLock.lock()
        let pending = continuations
        continuations = [:]
        let items = timeoutItems
        timeoutItems = [:]
        stateLock.unlock()
        for item in items.values { item.cancel() }
        for continuation in pending.values { continuation.resume(throwing: error) }
    }

    // MARK: - 读取

    /// readabilityHandler 回调：读取当前可用数据，按行切分后分发。
    private func consumeStdout(_ handle: FileHandle) {
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            stateLock.lock()
            let wasRunning = running
            running = false
            stateLock.unlock()
            if wasRunning {
                failAllPending(MCPError.processFailed("服务器「\(server)」已退出"))
            }
            return
        }

        bufferLock.lock()
        lineBuffer.append(data)
        var lines: [String] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(lineBuffer[lineBuffer.startIndex..<newline])
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        bufferLock.unlock()

        for line in lines { handleMessage(line) }
    }

    private func handleMessage(_ line: String) {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else { return }

        // 服务器主动发来的请求（带 id 与 method）：按 JSON-RPC 回应，避免其挂起。
        if let method = object["method"]?.stringValue, let id = object["id"]?.intValue {
            respondToServerRequest(method: method, id: id)
            return
        }

        // 通知（无 id）直接忽略。
        guard let id = object["id"]?.intValue else { return }

        if let error = object["error"]?.objectValue {
            let code = error["code"]?.intValue ?? -1
            let message = error["message"]?.stringValue ?? "未知错误"
            finish(id: id, result: .failure(MCPError.rpc(code: code, message: message)))
        } else {
            finish(id: id, result: .success(object["result"] ?? .null))
        }
    }

    private func respondToServerRequest(method: String, id: Int) {
        if method == "ping" {
            try? write(["jsonrpc": "2.0", "id": id, "result": JSONValue.object([:]).foundationValue])
        } else {
            try? write(["jsonrpc": "2.0", "id": id,
                        "error": ["code": -32601, "message": "Method not found: \(method)"]] as [String: Any])
        }
    }

    private static func consumeStderr(_ handle: FileHandle, server: String) {
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            FileHandle.standardError.write(Data("[mcp:\(server)] \(line)\n".utf8))
        }
    }
}
