import Foundation

// MARK: - 仓库来源

/// 一个社区仓库来源。
///
/// 社区仓库是任何按约定提供 `registry.json` 的目录（GitHub raw / 自建镜像 / 本地 `file://`）。
/// 之前地址写死在代码里，只能接作者的 `myna-hub`；现在来源是配置的一部分，
/// 可以接多个，安装时按条目各自回到它的来源取文件。
struct HubSource: Codable, Identifiable, Equatable, Sendable {
    /// 稳定标识（配置引用、去重与界面选择都用它）。
    var id: String
    /// 展示名。
    var name: String
    /// `registry.json` 所在目录的基址，必须以 `/` 结尾（自动补齐）。
    var base: String
    var enabled: Bool

    init(id: String, name: String, base: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.base = HubSource.normalize(base)
        self.enabled = enabled
    }

    /// 补齐结尾的斜杠；`file://` 也一视同仁。
    static func normalize(_ base: String) -> String {
        base.hasSuffix("/") ? base : base + "/"
    }

    /// 把用户输入的几种写法统一成基址：
    /// - `https://…/dir`、`file:///…` 原样保留（补结尾斜杠）
    /// - `/abs/path`、`~/path`、`./rel` 视为本地目录
    /// - `owner/repo` 或 `owner/repo@branch` 展开成 GitHub raw 地址
    static func expand(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("://") { return normalize(trimmed) }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") {
            let path = NSString(string: trimmed).expandingTildeInPath
            return normalize("file://" + path)
        }
        var spec = trimmed
        var branch = "main"
        if let at = spec.lastIndex(of: "@") {
            branch = String(spec[spec.index(after: at)...])
            spec = String(spec[..<at])
        }
        return normalize("https://raw.githubusercontent.com/\(spec)/\(branch)/")
    }

    /// 内置默认来源：作者的 Myna Hub。
    static var defaultMynaHub: HubSource {
        HubSource(id: "myna-hub", name: "Myna Hub",
                  base: "https://raw.githubusercontent.com/quyansiyuanwang/myna-hub/main/")
    }

    /// 展示用的短地址（去掉协议与结尾斜杠）。
    var displayBase: String {
        base.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// 多个来源合并后的结果。
struct MergedRegistry: Sendable {
    var skills: [HubSkill] = []
    var mcps: [HubMCP] = []
    var plugins: [HubPlugin] = []
    /// `"skill:<id>"` → 该条目来自哪个来源（安装时据此取文件）。
    var sourceByKey: [String: HubSource] = [:]
    /// 每个来源的加载结果，供界面显示「失败原因 / 条目数」。
    var results: [SourceResult] = []

    struct SourceResult: Identifiable, Sendable {
        var id: String { source.id }
        let source: HubSource
        var itemCount: Int
        /// 该来源新增的条目数（被更高优先级来源覆盖的不计）。
        var acceptedCount: Int
        var error: String?
    }

    func source(for kind: String, id: String) -> HubSource? {
        sourceByKey["\(kind):\(id)"]
    }
}

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
    /// 内置默认来源地址（供配置初始化使用）。
    static var defaultBase: String { HubSource.defaultMynaHub.base }

    /// 生成某个来源下的文件地址。
    static func url(_ relativePath: String, in source: HubSource) -> URL? {
        var rel = relativePath
        while rel.hasPrefix("/") { rel.removeFirst() }
        return URL(string: HubSource.normalize(source.base) + rel)
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

    /// 拉取并解析某个来源的 `registry.json`。
    static func fetchRegistry(from source: HubSource) async throws -> HubRegistry {
        guard let target = url("registry.json", in: source) else {
            throw MarketplaceError.invalidConfig("来源地址无效：\(source.base)")
        }
        let data = try await fetchData(target)
        do {
            return try JSONDecoder().decode(HubRegistry.self, from: data)
        } catch {
            throw MarketplaceError.decode(error.localizedDescription)
        }
    }

    /// 并发拉取全部启用的来源并按顺序合并。
    ///
    /// - 顺序即优先级：靠前的来源先占位，后续同 id 条目被忽略（界面会标出重复数）。
    /// - 单个来源失败不影响其它来源，失败原因逐条记录。
    static func fetchMerged(from sources: [HubSource]) async -> MergedRegistry {
        let enabled = sources.filter { $0.enabled }
        var merged = MergedRegistry()
        var taken = Set<String>()

        // 顺序合并：并发拉取但按配置顺序落位，保证优先级可预期。
        var loaded: [(HubSource, Result<HubRegistry, Error>)] = []
        await withTaskGroup(of: (HubSource, Result<HubRegistry, Error>).self) { group in
            for source in enabled {
                group.addTask {
                    do { return (source, .success(try await fetchRegistry(from: source))) }
                    catch { return (source, .failure(error)) }
                }
            }
            for await item in group { loaded.append(item) }
        }
        let order = Dictionary(uniqueKeysWithValues: enabled.enumerated().map { ($1.id, $0) })
        loaded.sort { (order[$0.0.id] ?? 0) < (order[$1.0.id] ?? 0) }

        for (source, result) in loaded {
            switch result {
            case .failure(let error):
                merged.results.append(.init(source: source, itemCount: 0, acceptedCount: 0,
                                            error: error.localizedDescription))
            case .success(let registry):
                var accepted = 0
                for skill in registry.skills {
                    let key = "skill:\(skill.id)"
                    guard !taken.contains(key) else { continue }
                    taken.insert(key)
                    merged.sourceByKey[key] = source
                    merged.skills.append(skill)
                    accepted += 1
                }
                for mcp in registry.mcps {
                    let key = "mcp:\(mcp.id)"
                    guard !taken.contains(key) else { continue }
                    taken.insert(key)
                    merged.sourceByKey[key] = source
                    merged.mcps.append(mcp)
                    accepted += 1
                }
                for plugin in registry.plugins {
                    let key = "plugin:\(plugin.id)"
                    guard !taken.contains(key) else { continue }
                    taken.insert(key)
                    merged.sourceByKey[key] = source
                    merged.plugins.append(plugin)
                    accepted += 1
                }
                let total = registry.skills.count + registry.mcps.count + registry.plugins.count
                merged.results.append(.init(source: source, itemCount: total,
                                            acceptedCount: accepted, error: nil))
            }
        }
        return merged
    }

    // MARK: 本地路径

    static var skillsDir: String { LocalResources.skillsDir }
    static var mcpConfigPath: String { MCPManager.configPath }

    static func skillPath(id: String) -> String { skillsDir + "/" + id + "/SKILL.md" }

    // MARK: 安装

    static func installSkill(_ skill: HubSkill, from source: HubSource) async throws {
        guard let target = url(skill.path + "/SKILL.md", in: source) else {
            throw MarketplaceError.invalidConfig("来源地址无效：\(source.base)")
        }
        let data = try await fetchData(target)
        let fm = FileManager.default
        let dir = skillsDir + "/" + skill.id
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir + "/SKILL.md"))
    }

    static func installMCP(_ mcp: HubMCP, from source: HubSource) async throws {
        guard let target = url(mcp.path + "/mcp.json", in: source) else {
            throw MarketplaceError.invalidConfig("来源地址无效：\(source.base)")
        }
        let data = try await fetchData(target)
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
    static func installPlugin(_ plugin: HubPlugin, merged: MergedRegistry,
                              defaultSource: HubSource) async throws {
        for id in plugin.skills {
            guard let skill = merged.skills.first(where: { $0.id == id }) else {
                throw MarketplaceError.missingReference("skill:\(id)")
            }
            let source = merged.source(for: "skill", id: id) ?? defaultSource
            try await installSkill(skill, from: source)
        }
        for id in plugin.mcps {
            guard let mcp = merged.mcps.first(where: { $0.id == id }) else {
                throw MarketplaceError.missingReference("mcp:\(id)")
            }
            let source = merged.source(for: "mcp", id: id) ?? defaultSource
            try await installMCP(mcp, from: source)
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

    /// 按种类与 id 从**全部启用来源**安装；`kind` 取 `skill` / `mcp` / `plugin`。
    ///
    /// 条目可能来自任意一个来源，安装时回到它自己的来源取文件。
    static func installFromRegistry(kind: String, id: String,
                                    sources: [HubSource]) async throws {
        let merged = await fetchMerged(from: sources)
        let fallback = sources.first { $0.enabled } ?? HubSource.defaultMynaHub
        let source = merged.source(for: kind, id: id) ?? fallback
        switch kind {
        case "skill":
            guard let skill = merged.skills.first(where: { $0.id == id }) else {
                throw MarketplaceError.notFound(id)
            }
            try await installSkill(skill, from: source)
        case "mcp":
            guard let mcp = merged.mcps.first(where: { $0.id == id }) else {
                throw MarketplaceError.notFound(id)
            }
            try await installMCP(mcp, from: source)
        case "plugin":
            guard let plugin = merged.plugins.first(where: { $0.id == id }) else {
                throw MarketplaceError.notFound(id)
            }
            try await installPlugin(plugin, merged: merged, defaultSource: source)
        default:
            throw MarketplaceError.invalidConfig("未知类型「\(kind)」，应为 skill / mcp / plugin")
        }
    }

    /// 拉取合并结果（CLI 列表用）。
    static func listAll(sources: [HubSource]) async -> MergedRegistry {
        await fetchMerged(from: sources)
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
    /// 各来源的加载结果（条目数 / 失败原因）。
    @Published var sourceResults: [MergedRegistry.SourceResult] = []
    /// 当前筛选的来源；nil 表示全部来源。
    @Published var sourceFilter: String?

    /// 合并结果里的来源归属，安装时据此回到条目的来源。
    private var merged = MergedRegistry()

    /// 以 `skill:<id>` / `mcp:<id>` / `plugin:<id>` 为键记录安装状态。
    @Published private(set) var states: [String: InstallState] = [:]

    private init() {}

    /// 找不到归属时使用的来源（第一个启用的，或内置默认）。
    private var fallbackSource: HubSource {
        sources.first { $0.enabled } ?? .defaultMynaHub
    }

    // MARK: 状态键

    static func key(_ kind: String, _ id: String) -> String { "\(kind):\(id)" }

    func state(key: String) -> InstallState { states[key] ?? .idle }

    private func set(_ state: InstallState, key: String) {
        states[key] = state
    }

    // MARK: 刷新

    /// 当前配置的来源列表。
    var sources: [HubSource] { SettingsStore.shared.settings.hubSources }

    func refresh() async {
        isLoading = true
        lastError = nil
        let merged = await MarketplaceInstaller.fetchMerged(from: sources)
        self.merged = merged
        skills = merged.skills
        mcps = merged.mcps
        plugins = merged.plugins
        sourceResults = merged.results
        // 全部来源都失败时给出汇总错误；部分失败只在来源列表里标注。
        let failures = merged.results.filter { $0.error != nil }
        if failures.count == merged.results.count, let first = failures.first {
            lastError = "所有来源均加载失败：" + (first.error ?? "")
        } else {
            lastError = nil
        }
        lastUpdated = Date()
        synchronizeStates()
        isLoading = false
    }

    /// 某个条目来自哪个来源。
    func source(forKind kind: String, id: String) -> HubSource? {
        merged.source(for: kind, id: id)
    }

    /// 按来源筛选。
    func matchesSource(kind: String, id: String) -> Bool {
        guard let filter = sourceFilter else { return true }
        return merged.source(for: kind, id: id)?.id == filter
    }

    // MARK: 来源管理

    func addSource(name: String, base: String) {
        let expanded = HubSource.expand(base)
        guard !expanded.isEmpty else { return }
        var settings = SettingsStore.shared.settings
        guard !settings.hubSources.contains(where: { $0.base == expanded }) else { return }
        let id = "src-" + UUID().uuidString.prefix(8).lowercased()
        settings.hubSources.append(HubSource(id: id,
                                            name: name.isEmpty ? expanded : name,
                                            base: expanded))
        SettingsStore.shared.settings = settings
        Task { await refresh() }
    }

    func removeSource(id: String) {
        var settings = SettingsStore.shared.settings
        settings.hubSources.removeAll { $0.id == id }
        SettingsStore.shared.settings = settings
        if sourceFilter == id { sourceFilter = nil }
        Task { await refresh() }
    }

    func setSourceEnabled(id: String, enabled: Bool) {
        var settings = SettingsStore.shared.settings
        guard let index = settings.hubSources.firstIndex(where: { $0.id == id }) else { return }
        settings.hubSources[index].enabled = enabled
        SettingsStore.shared.settings = settings
        Task { await refresh() }
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
            let source = merged.source(for: "skill", id: skill.id) ?? fallbackSource
            try await MarketplaceInstaller.installSkill(skill, from: source)
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
            let source = merged.source(for: "mcp", id: mcp.id) ?? fallbackSource
            try await MarketplaceInstaller.installMCP(mcp, from: source)
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
            let source = merged.source(for: "plugin", id: plugin.id) ?? fallbackSource
            try await MarketplaceInstaller.installPlugin(plugin, merged: merged,
                                                         defaultSource: source)
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
