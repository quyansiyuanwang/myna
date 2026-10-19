import Foundation

// MARK: - 仓库数据模型

/// 社区仓库 `registry.json` 的顶层结构；缺失的字段按空列表处理。
struct HubRegistry: Decodable, Sendable {
    let version: Int
    let skills: [HubSkill]
    let mcps: [HubMCP]
    let plugins: [HubPlugin]

    enum CodingKeys: String, CodingKey { case version, skills, mcps, plugins }

    init(version: Int = 1, skills: [HubSkill] = [], mcps: [HubMCP] = [], plugins: [HubPlugin] = []) {
        self.version = version
        self.skills = skills
        self.mcps = mcps
        self.plugins = plugins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        skills = (try? container.decode([HubSkill].self, forKey: .skills)) ?? []
        mcps = (try? container.decode([HubMCP].self, forKey: .mcps)) ?? []
        plugins = (try? container.decode([HubPlugin].self, forKey: .plugins)) ?? []
    }
}

/// 仓库中的技能条目。
struct HubSkill: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let tags: [String]
    let author: String
    let path: String


    enum CodingKeys: String, CodingKey { case id, name, description, tags, author, path }

    init(id: String, name: String, description: String = "", tags: [String] = [], author: String = "", path: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
        self.author = author
        self.path = path ?? "skills/\(id)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? id
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        author = (try? container.decode(String.self, forKey: .author)) ?? ""
        path = (try? container.decode(String.self, forKey: .path)) ?? "skills/\(id)"
    }
}

/// 仓库中的 MCP 服务器条目。
struct HubMCP: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let tags: [String]
    let author: String
    let path: String

    var runtime: String?

    enum CodingKeys: String, CodingKey { case id, name, description, tags, author, path, runtime }

    init(id: String, name: String, description: String = "", tags: [String] = [], author: String = "", path: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
        self.author = author
        self.path = path ?? "mcps/\(id)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? id
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        runtime = try? container.decode(String.self, forKey: .runtime)
        author = (try? container.decode(String.self, forKey: .author)) ?? ""
        path = (try? container.decode(String.self, forKey: .path)) ?? "mcps/\(id)"
    }
}

/// 仓库中的插件条目：引用若干技能与 MCP。
struct HubPlugin: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let tags: [String]
    let author: String
    let path: String
    let skills: [String]
    let mcps: [String]

    enum CodingKeys: String, CodingKey { case id, name, description, tags, author, path, skills, mcps }

    init(id: String, name: String, description: String = "", tags: [String] = [], author: String = "",
         path: String? = nil, skills: [String] = [], mcps: [String] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
        self.author = author
        self.path = path ?? "plugins/\(id)"
        self.skills = skills
        self.mcps = mcps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? id
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        author = (try? container.decode(String.self, forKey: .author)) ?? ""
        path = (try? container.decode(String.self, forKey: .path)) ?? "plugins/\(id)"
        skills = (try? container.decode([String].self, forKey: .skills)) ?? []
        mcps = (try? container.decode([String].self, forKey: .mcps)) ?? []
    }
}

// MARK: - 安装状态

/// 单个条目的安装状态，供界面显示进度与结果。
enum InstallState: Equatable {
    case idle
    case installing
    case installed
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "安装"
        case .installing: return "安装中…"
        case .installed: return "已安装"
        case .failed: return "重试"
        }
    }
}

// MARK: - 错误

enum MarketplaceError: Error, LocalizedError {
    case network(String)
    case badResponse
    case http(Int, String)
    case decode(String)
    case notFound(String)
    case missingReference(String)
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .network(let message): return "网络请求失败：\(message)"
        case .badResponse: return "服务器返回了无法识别的响应"
        case .http(let code, let name): return "下载 \(name) 失败：HTTP \(code)"
        case .decode(let message): return "解析数据失败：\(message)"
        case .notFound(let id): return "在仓库中找不到「\(id)」"
        case .missingReference(let id): return "插件引用的资源不存在：\(id)"
        case .invalidConfig(let message): return "配置无效：\(message)"
        }
    }
}

// MARK: - 安装器（与界面无关，可在 CLI 中调用）

/// 负责从社区仓库下载并落地技能、MCP 与插件。
enum MarketplaceInstaller {
    /// 默认仓库地址；可用 `MYNA_HUB_BASE` 覆盖（便于镜像与离线测试）。
    static let defaultBase = "https://raw.githubusercontent.com/quyansiyuanwang/myna-hub/main/"

    static var baseURLString: String {
        var base = ProcessInfo.processInfo.environment["MYNA_HUB_BASE"] ?? defaultBase
        if !base.hasSuffix("/") { base += "/" }
        return base
    }

    static func url(_ relativePath: String) -> URL {
        var rel = relativePath
        while rel.hasPrefix("/") { rel.removeFirst() }
        return URL(string: baseURLString + rel) ?? URL(string: defaultBase)!
    }

    /// 下载单个文件；`file://` 走本地读取，便于离线测试。
    static func fetchData(_ url: URL) async throws -> Data {
        if url.isFileURL {
            do { return try Data(contentsOf: url) }
            catch { throw MarketplaceError.network(error.localizedDescription) }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Myna", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MarketplaceError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MarketplaceError.badResponse }
        guard http.statusCode == 200 else {
            throw MarketplaceError.http(http.statusCode, url.lastPathComponent)
        }
        return data
    }

    /// 拉取并解析 `registry.json`。
    static func fetchRegistry() async throws -> HubRegistry {
        let data = try await fetchData(url("registry.json"))
        do {
            return try JSONDecoder().decode(HubRegistry.self, from: data)
        } catch {
            throw MarketplaceError.decode(error.localizedDescription)
        }
    }

    // MARK: 本地路径

    static var skillsDir: String { LocalResources.skillsDir }
    static var mcpConfigPath: String { MCPManager.configPath }

    static func skillPath(id: String) -> String { skillsDir + "/" + id + "/SKILL.md" }

    // MARK: 安装

    static func installSkill(_ skill: HubSkill) async throws {
        let data = try await fetchData(url(skill.path + "/SKILL.md"))
        let fm = FileManager.default
        let dir = skillsDir + "/" + skill.id
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir + "/SKILL.md"))
    }

    static func installMCP(_ mcp: HubMCP) async throws {
        let data = try await fetchData(url(mcp.path + "/mcp.json"))
        let config: MCPServerConfig
        do {
            config = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        } catch {
            throw MarketplaceError.decode(error.localizedDescription)
        }
        guard !config.command.isEmpty else {
            throw MarketplaceError.invalidConfig("\(mcp.id) 缺少 command 字段")
        }
        try mergeMCPServer(id: mcp.id, config: config)
    }

    /// 安装插件引用的全部技能与 MCP。
    static func installPlugin(_ plugin: HubPlugin, skills: [HubSkill], mcps: [HubMCP]) async throws {
        for id in plugin.skills {
            guard let skill = skills.first(where: { $0.id == id }) else {
                throw MarketplaceError.missingReference("skill:\(id)")
            }
            try await installSkill(skill)
        }
        for id in plugin.mcps {
            guard let mcp = mcps.first(where: { $0.id == id }) else {
                throw MarketplaceError.missingReference("mcp:\(id)")
            }
            try await installMCP(mcp)
        }
    }

    // MARK: 卸载

    static func uninstallSkill(id: String) throws {
        let dir = skillsDir + "/" + id
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else { return }
        try fm.removeItem(atPath: dir)
    }

    static func uninstallMCP(id: String) throws {
        try mergeMCPServer(id: id, config: nil)
        MCPManager.shared.reload()
    }

    // MARK: MCP 配置读写

    /// 将服务器条目合并进 `mcp.json`；`config` 为 nil 时删除该条目。
    /// 保留文件中其它未知字段与服务器，写回权限 0600。
    static func mergeMCPServer(id: String, config: MCPServerConfig?) throws {
        let path = mcpConfigPath
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = object
        }
        var servers = root["servers"] as? [String: Any] ?? [:]
        if let config {
            var entry: [String: Any] = ["command": config.command]
            if let args = config.args { entry["args"] = args }
            if let env = config.env { entry["env"] = env }
            servers[id] = entry
        } else {
            servers.removeValue(forKey: id)
        }
        root["servers"] = servers

        let out: Data
        do {
            out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw MarketplaceError.invalidConfig(error.localizedDescription)
        }
        try out.write(to: URL(fileURLWithPath: path))
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// 读取当前 `mcp.json` 中已登记的服务器 id。
    static func installedMCPIDs() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: mcpConfigPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["servers"] as? [String: Any] else {
            return []
        }
        return Set(servers.keys)
    }

    static func isSkillInstalled(id: String) -> Bool {
        FileManager.default.fileExists(atPath: skillPath(id: id))
    }

    static func isMCPInstalled(id: String) -> Bool {
        installedMCPIDs().contains(id)
    }

    // MARK: CLI 入口

    /// 按种类与 id 从仓库安装；`kind` 取 `skill` / `mcp` / `plugin`。
    static func installFromRegistry(kind: String, id: String) async throws {
        let registry = try await fetchRegistry()
        switch kind {
        case "skill":
            guard let skill = registry.skills.first(where: { $0.id == id }) else {
                throw MarketplaceError.notFound(id)
            }
            try await installSkill(skill)
        case "mcp":
            guard let mcp = registry.mcps.first(where: { $0.id == id }) else {
                throw MarketplaceError.notFound(id)
            }
            try await installMCP(mcp)
        case "plugin":
            guard let plugin = registry.plugins.first(where: { $0.id == id }) else {
                throw MarketplaceError.notFound(id)
            }
            try await installPlugin(plugin, skills: registry.skills, mcps: registry.mcps)
        default:
            throw MarketplaceError.invalidConfig("未知类型「\(kind)」，应为 skill / mcp / plugin")
        }
    }
}

// MARK: - 界面状态（主线程）

/// 市场界面状态：持有仓库列表、每个条目的安装状态与错误信息。
@MainActor
final class Marketplace: ObservableObject {
    static let shared = Marketplace()

    @Published var skills: [HubSkill] = []
    @Published var mcps: [HubMCP] = []
    @Published var plugins: [HubPlugin] = []
    @Published var lastError: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    /// 以 `skill:<id>` / `mcp:<id>` / `plugin:<id>` 为键记录安装状态。
    @Published private(set) var states: [String: InstallState] = [:]

    private init() {}

    // MARK: 状态键

    static func key(_ kind: String, _ id: String) -> String { "\(kind):\(id)" }

    func state(key: String) -> InstallState { states[key] ?? .idle }

    private func set(_ state: InstallState, key: String) {
        states[key] = state
    }

    // MARK: 刷新

    func refresh() async {
        isLoading = true
        lastError = nil
        do {
            let registry = try await MarketplaceInstaller.fetchRegistry()
            skills = registry.skills
            mcps = registry.mcps
            plugins = registry.plugins
            lastUpdated = Date()
            synchronizeStates()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// 用本地文件系统状态同步「已安装 / 未安装」，保留进行中与失败状态。
    func synchronizeStates() {
        for skill in skills {
            let key = Marketplace.key("skill", skill.id)
            if case .installing = state(key: key) { continue }
            if case .failed = state(key: key) { continue }
            set(MarketplaceInstaller.isSkillInstalled(id: skill.id) ? .installed : .idle, key: key)
        }
        for mcp in mcps {
            let key = Marketplace.key("mcp", mcp.id)
            if case .installing = state(key: key) { continue }
            if case .failed = state(key: key) { continue }
            set(MarketplaceInstaller.isMCPInstalled(id: mcp.id) ? .installed : .idle, key: key)
        }
        for plugin in plugins {
            let key = Marketplace.key("plugin", plugin.id)
            if case .installing = state(key: key) { continue }
            if case .failed = state(key: key) { continue }
            set(isInstalled(plugin) ? .installed : .idle, key: key)
        }
    }

    // MARK: 安装

    func install(skill: HubSkill) async {
        let key = Marketplace.key("skill", skill.id)
        set(.installing, key: key)
        do {
            try await MarketplaceInstaller.installSkill(skill)
            set(.installed, key: key)
            lastError = nil
        } catch {
            set(.failed(error.localizedDescription), key: key)
            lastError = error.localizedDescription
        }
    }

    func install(mcp: HubMCP) async {
        let key = Marketplace.key("mcp", mcp.id)
        set(.installing, key: key)
        do {
            try await MarketplaceInstaller.installMCP(mcp)
            set(.installed, key: key)
            lastError = nil
        } catch {
            set(.failed(error.localizedDescription), key: key)
            lastError = error.localizedDescription
        }
    }

    func install(plugin: HubPlugin) async {
        let key = Marketplace.key("plugin", plugin.id)
        set(.installing, key: key)
        do {
            try await MarketplaceInstaller.installPlugin(plugin, skills: skills, mcps: mcps)
            // 插件的组成部分也同步标记为已安装
            for id in plugin.skills {
                set(.installed, key: Marketplace.key("skill", id))
            }
            for id in plugin.mcps {
                set(.installed, key: Marketplace.key("mcp", id))
            }
            set(.installed, key: key)
            lastError = nil
        } catch {
            set(.failed(error.localizedDescription), key: key)
            lastError = error.localizedDescription
        }
    }

    // MARK: 卸载

    func uninstall(skill: HubSkill) async {
        let key = Marketplace.key("skill", skill.id)
        do {
            try MarketplaceInstaller.uninstallSkill(id: skill.id)
            set(.idle, key: key)
            lastError = nil
        } catch {
            set(.failed(error.localizedDescription), key: key)
            lastError = error.localizedDescription
        }
    }

    func uninstall(mcp: HubMCP) async {
        let key = Marketplace.key("mcp", mcp.id)
        do {
            try MarketplaceInstaller.uninstallMCP(id: mcp.id)
            set(.idle, key: key)
            lastError = nil
        } catch {
            set(.failed(error.localizedDescription), key: key)
            lastError = error.localizedDescription
        }
    }

    func uninstall(plugin: HubPlugin) async {
        for id in plugin.skills {
            guard let skill = skills.first(where: { $0.id == id }) else { continue }
            await uninstall(skill: skill)
        }
        for id in plugin.mcps {
            guard let mcp = mcps.first(where: { $0.id == id }) else { continue }
            await uninstall(mcp: mcp)
        }
        set(.idle, key: Marketplace.key("plugin", plugin.id))
    }

    // MARK: 已安装判断

    func isInstalled(_ skill: HubSkill) -> Bool {
        MarketplaceInstaller.isSkillInstalled(id: skill.id)
    }

    func isInstalled(_ mcp: HubMCP) -> Bool {
        MarketplaceInstaller.isMCPInstalled(id: mcp.id)
    }

    func isInstalled(_ plugin: HubPlugin) -> Bool {
        let skillsReady = plugin.skills.allSatisfy { MarketplaceInstaller.isSkillInstalled(id: $0) }
        let mcpsReady = plugin.mcps.allSatisfy { MarketplaceInstaller.isMCPInstalled(id: $0) }
        return skillsReady && mcpsReady
    }
}
