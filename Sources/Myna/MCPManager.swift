import Foundation
import PiKit

/// `~/.config/myna/mcp.json` 中单个服务器的配置。
struct MCPServerConfig: Codable, Sendable {
    var command: String
    var args: [String]?
    var env: [String: String]?

    enum CodingKeys: String, CodingKey { case command, args, env }
}

/// `mcp.json` 顶层结构；缺少 `servers` 时视为空列表。
struct MCPConfigFile: Codable, Sendable {
    var servers: [String: MCPServerConfig]

    enum CodingKeys: String, CodingKey { case servers }

    init(servers: [String: MCPServerConfig]) {
        self.servers = servers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = (try? container.decode([String: MCPServerConfig].self, forKey: .servers)) ?? [:]
    }
}

/// MCP 管理错误。
enum MCPManagerError: Error, LocalizedError {
    case unknownTool(String)
    case serverUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "未知的 MCP 工具：\(name)"
        case .serverUnavailable(let server):
            return "MCP 服务器不可用：\(server)"
        }
    }
}

/// 已加载的 MCP 工具（含命名空间映射）。
private struct MCPToolEntry: Sendable {
    let namespaced: String
    let server: String
    let tool: String
    let description: String
    let schema: JSONValue
}

/// 管理 `~/.config/myna/mcp.json` 中配置的所有 MCP 服务器。
///
/// 服务器在首次需要时异步启动并缓存工具列表；工具名统一为
/// `mcp__<server>__<tool>`（非法字符替换为 `_`）。既可异步调用
/// （``call(namespaced:arguments:)``），也提供同步桥接
/// （``callSync(namespaced:arguments:timeout:)``）供 `ToolRunner.run` 使用。
final class MCPManager: @unchecked Sendable {
    static let shared = MCPManager()

    private let lock = NSLock()
    private var clients: [String: MCPClient] = [:]
    private var entries: [MCPToolEntry] = []
    private var index: [String: MCPToolEntry] = [:]
    private var startupTask: Task<Void, Never>?
    private var generation = 0

    private init() {}

    // MARK: - 配置

    /// 配置文件路径；可用 `MYNA_MCP_CONFIG` 覆盖（便于测试/多环境）。
    static var configPath: String {
        if let override = ProcessInfo.processInfo.environment["MYNA_MCP_CONFIG"], !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return NSString(string: "~/.config/myna/mcp.json").expandingTildeInPath
    }

    /// 工具目录：`(name, description, schema)`，name 已命名空间化。
    func tools() -> [(name: String, description: String, schema: JSONValue)] {
        start()
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.map { ($0.namespaced, $0.description, $0.schema) }
    }

    // MARK: - 生命周期

    /// 异步启动全部服务器（不阻塞 UI）。重复调用无副作用。
    func start() {
        lock.lock()
        if startupTask == nil {
            generation += 1
            let gen = generation
            startupTask = Task.detached(priority: .utility) { [weak self] in
                await self?.loadAndStart(generation: gen)
            }
        }
        lock.unlock()
    }

    /// 同步等待启动完成（仅用于 CLI 等可安全阻塞的上下文），最多 `timeout` 秒。
    func waitForStartup(timeout: TimeInterval = 15) {
        start()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) { [weak self] in
            await self?.ensureStarted()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// 关闭全部客户端并清空缓存；随后可再次 ``start()``。
    func shutdown() {
        lock.lock()
        let existing = clients
        clients = [:]
        entries = []
        index = [:]
        startupTask = nil
        generation += 1
        lock.unlock()
        for client in existing.values { client.shutdown() }
    }

    /// 重新读取配置并重启全部服务器。
    func reload() {
        lock.lock()
        let existing = clients
        clients = [:]
        entries = []
        index = [:]
        startupTask = nil
        generation += 1
        lock.unlock()
        for client in existing.values { client.shutdown() }
        start()
    }

    // MARK: - 调用

    /// 异步调用某个命名空间化的 MCP 工具。
    func call(namespaced: String, arguments: JSONValue) async throws -> String {
        await ensureStarted()
        guard let entry = cachedEntry(namespaced) else {
            throw MCPManagerError.unknownTool(namespaced)
        }
        guard let client = cachedClient(server: entry.server) else {
            throw MCPManagerError.serverUnavailable(entry.server)
        }
        return try await client.callTool(name: entry.tool, arguments: arguments)
    }

    private func cachedEntry(_ namespaced: String) -> MCPToolEntry? {
        lock.lock()
        defer { lock.unlock() }
        return index[namespaced]
    }

    private func cachedClient(server: String) -> MCPClient? {
        lock.lock()
        defer { lock.unlock() }
        return clients[server]
    }

    /// 同步桥接：在后台任务中执行 ``call(namespaced:arguments:)``，最多等待
    /// `timeout` 秒。超时不会阻塞主线程，而是返回可读的错误字符串。
    func callSync(namespaced: String, arguments: JSONValue, timeout: TimeInterval = 25) -> String {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                box.set(.failure(MCPError.notRunning))
                semaphore.signal()
                return
            }
            do {
                box.set(.success(try await self.call(namespaced: namespaced, arguments: arguments)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return "MCP 调用超时：\(namespaced)（服务器可能未就绪或阻塞）"
        }
        switch box.get() {
        case .success(let text):
            return text
        case .failure(let error):
            return "MCP 调用失败：\(error.localizedDescription)"
        case .none:
            return "MCP 调用失败：未知错误"
        }
    }

    // MARK: - 启动实现

    private func ensureStarted() async {
        start()
        await currentStartupTask()?.value
    }

    private func currentStartupTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return startupTask
    }

    private func loadAndStart(generation gen: Int) async {
        let config = loadConfig()
        var newClients: [String: MCPClient] = [:]
        var newEntries: [MCPToolEntry] = []
        var newIndex: [String: MCPToolEntry] = [:]

        for (server, serverConfig) in config.servers {
            let client = MCPClient(server: server,
                                   command: serverConfig.command,
                                   args: serverConfig.args ?? [],
                                   env: serverConfig.env ?? [:])
            do {
                try await client.start()
                let tools = try await client.listTools()
                let namespace = MCPManager.sanitize(server)
                for tool in tools {
                    let namespaced = "mcp__\(namespace)__\(MCPManager.sanitize(tool.name))"
                    // 命名空间冲突时只保留第一个，避免向模型声明重名函数。
                    guard newIndex[namespaced] == nil else { continue }
                    let entry = MCPToolEntry(namespaced: namespaced,
                                             server: server,
                                             tool: tool.name,
                                             description: tool.description,
                                             schema: tool.inputSchema)
                    newEntries.append(entry)
                    newIndex[namespaced] = entry
                }
                newClients[server] = client
            } catch {
                FileHandle.standardError.write(Data("[mcp] 启动服务器「\(server)」失败：\(error.localizedDescription)\n".utf8))
                client.shutdown()
            }
        }

        if !commit(generation: gen, clients: newClients, entries: newEntries, index: newIndex) {
            for client in newClients.values { client.shutdown() }
        }
    }

    /// 提交启动结果；若期间发生 reload/shutdown，则返回 false。
    private func commit(generation gen: Int,
                       clients newClients: [String: MCPClient],
                       entries newEntries: [MCPToolEntry],
                       index newIndex: [String: MCPToolEntry]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == gen, startupTask != nil else { return false }
        clients = newClients
        entries = newEntries
        index = newIndex
        return true
    }

    private func loadConfig() -> MCPConfigFile {
        let path = MCPManager.configPath
        ensureConfigFile(at: path)
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else {
            return MCPConfigFile(servers: [:])
        }
        return config
    }

    /// 首次运行时创建示例配置与说明文件（不覆盖已有内容）。
    private func ensureConfigFile(at path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: path) {
            let example = """
            {
              "servers": {}
            }
            """
            try? example.write(toFile: path, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }

        let readme = dir + "/mcp.README.md"
        if !fm.fileExists(atPath: readme) {
            let text = """
            # MCP 服务器

            Myna 支持通过 Model Context Protocol（stdio 传输）接入外部工具服务器。
            在 `mcp.json` 中登记服务器，Myna 启动后会异步拉起它们，并把工具以
            `mcp__<服务器>__<工具>` 的形式暴露给模型。

            示例：

            ```json
            {
              "servers": {
                "filesystem": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                  "env": {}
                }
              }
            }
            ```

            - `command`：可执行文件（经 `/usr/bin/env` 启动，支持 npx / uvx 等）。
            - `args`：传给命令的参数数组，可省略。
            - `env`：追加或覆盖的环境变量，可省略。

            修改后需重启 Myna，或在代码中调用 `MCPManager.shared.reload()`。
            服务器的 stderr 会带上 `[mcp:<服务器>]` 前缀输出到 Myna 的 stderr。
            """
            try? text.write(toFile: readme, atomically: true, encoding: .utf8)
        }
    }

    /// 命名空间化时把非 `[A-Za-z0-9_-]` 字符替换为 `_`。
    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        var result = ""
        for scalar in raw.unicodeScalars {
            result.append(allowed.contains(scalar) ? Character(scalar) : "_")
        }
        return result.isEmpty ? "_" : result
    }

    /// 把模型传入的 Foundation 参数转成 `JSONValue`。
    static func jsonValue(from object: [String: Any]) -> JSONValue {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return value
    }
}

/// 跨线程传递同步调用结果的小盒子。
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?

    func set(_ result: Result<String, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - 配置读写（供设置界面管理服务器）

extension MCPManager {
    /// 当前 `mcp.json` 中登记的所有服务器（按名称排序）。
    func configuredServers() -> [(name: String, config: MCPServerConfig)] {
        loadConfig().servers
            .map { (name: $0.key, config: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 新增或覆盖一个服务器；写盘后调用 ``reload()`` 使其生效。
    @discardableResult
    func upsertServer(name: String, config: MCPServerConfig) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var servers = loadConfig().servers
        servers[trimmed] = config
        return writeConfig(servers)
    }

    /// 删除一个服务器。
    @discardableResult
    func removeServer(name: String) -> Bool {
        var servers = loadConfig().servers
        guard servers.removeValue(forKey: name) != nil else { return false }
        return writeConfig(servers)
    }

    /// 写回 `mcp.json`（保持 `{"servers": {…}}` 结构，权限 0600）。
    private func writeConfig(_ servers: [String: MCPServerConfig]) -> Bool {
        let path = MCPManager.configPath
        ensureConfigFile(at: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(MCPConfigFile(servers: servers)) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    /// 某个服务器当前暴露的工具数量（未加载时为 0）。
    func toolCount(forServer name: String) -> Int {
        tools().filter { $0.name.hasPrefix("mcp__\(MCPManager.sanitize(name))__") }.count
    }

    /// 已加载的 MCP 工具总数。
    var loadedToolCount: Int { tools().count }
}

// MARK: - 外部运行时检测

/// MCP 服务器常用的外部运行时。
///
/// Myna 本体（含联网搜索、网页抓取、编码工具）是原生 Swift 实现，**不需要任何外部运行时**；
/// 但部分 MCP 服务器以 `npx`（Node.js）或 `uvx`（uv/Python）方式启动。
/// 这里用于在界面上提前标注，避免用户装完才发现命令不存在。
enum MCPRuntime: String, CaseIterable, Sendable {
    case node
    case uv
    case none

    var label: String {
        switch self {
        case .node: return "需 Node"
        case .uv: return "需 uv"
        case .none: return "无依赖"
        }
    }

    /// 该运行时是否已在本机可用。
    var isAvailable: Bool { MCPRuntime.available.contains(self) }

    /// 用于提示的安装命令。
    var installHint: String? {
        switch self {
        case .node: return "brew install node"
        case .uv: return "brew install uv"
        case .none: return nil
        }
    }

    /// 依据启动命令推断所需运行时。
    static func infer(command: String) -> MCPRuntime {
        let name = (command as NSString).lastPathComponent.lowercased()
        switch name {
        case "npx", "node", "npm", "pnpm", "yarn", "bun", "bunx", "deno": return .node
        case "uvx", "uv", "python", "python3", "pipx": return .uv
        default: return .none
        }
    }

    /// 本机已可用的运行时（进程启动时探测一次）。
    static let available: Set<MCPRuntime> = {
        var found: Set<MCPRuntime> = []
        if which("npx") != nil || which("node") != nil { found.insert(.node) }
        if which("uvx") != nil || which("uv") != nil { found.insert(.uv) }
        return found
    }()

    /// 在常见路径中查找可执行文件（GUI 应用的 PATH 通常不含 Homebrew）。
    private static func which(_ tool: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "~/.local/bin"]
        let fm = FileManager.default
        for dir in dirs {
            let path = (NSString(string: dir).expandingTildeInPath as NSString)
                .appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        // 再退回 PATH 环境变量
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent(tool)
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
