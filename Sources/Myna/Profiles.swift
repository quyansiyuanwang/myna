import Foundation

// MARK: - 旧版模型档案（仅迁移用）

/// 旧版的「模型档案」：只保存模型相关字段。
///
/// 新版本不再使用它保存新数据，仅保留解码能力以便把
/// `model_profiles` 迁移成供应商 / 模型（见 ``SettingsStore/migrateLegacyModelData()``）。
struct ModelProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
    /// 接口类型（协议），取值同 `APIType`。
    var api: String
    var reasoningEffort: String
    var thinkingBudget: Int
    var maxTokens: Int
    var temperature: Double

    enum CodingKeys: String, CodingKey {
        case id, name
        case baseURL = "base_url", apiKey = "api_key"
        case model, api
        case reasoningEffort = "reasoning_effort"
        case thinkingBudget = "thinking_budget"
        case maxTokens = "max_tokens"
        case temperature
    }

    /// 逐字段解码并提供默认值，保证旧配置 / 缺字段时仍可读取。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys, _ d: String) -> String { (try? c.decode(String.self, forKey: k)) ?? d }
        func int(_ k: CodingKeys, _ d: Int) -> Int { (try? c.decode(Int.self, forKey: k)) ?? d }
        func dbl(_ k: CodingKeys, _ d: Double) -> Double { (try? c.decode(Double.self, forKey: k)) ?? d }

        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = str(.name, "")
        baseURL = str(.baseURL, "https://api.deepseek.com")
        apiKey = str(.apiKey, "")
        model = str(.model, "")
        api = str(.api, APIType.openAICompletions.rawValue)
        reasoningEffort = str(.reasoningEffort, "")
        thinkingBudget = int(.thinkingBudget, 0)
        maxTokens = int(.maxTokens, 8192)
        temperature = dbl(.temperature, 0.7)
    }
}

// MARK: - 配置方案（完整配置快照）

/// `SettingsStore` 上的配置方案操作。
///
/// 每个方案是 `~/.config/myna/profiles/<name>.json` 里的**一份完整 `AppSettings` 快照**
/// （与 `config.json` 同构，`model_profiles` / `model_list` 写为空数组）。
/// 因此切换方案会连带恢复外观、语音、对话、行为、工具等全部设置，
/// 而不只是模型相关字段。
extension SettingsStore {

    /// 方案目录。
    static var profilesDirectory: String {
        NSString(string: "~/.config/myna/profiles").expandingTildeInPath
    }

    /// 列出全部方案名（按名称排序）。
    func listProfiles() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.profilesDirectory) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 把当前设置保存为方案（同名覆盖）。
    @discardableResult
    func saveProfile(named name: String) -> Bool {
        guard let url = profileURL(for: name) else { return false }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(profileSnapshot()) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: Self.profilesDirectory,
                                                   withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// 应用方案：整体替换当前设置（含供应商 / 模型与全部其他设置）。
    @discardableResult
    func applyProfile(named name: String) -> Bool {
        guard let url = profileURL(for: name),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(AppSettings.self, from: data) else { return false }
        settings = snapshot
        migrateLegacyModelData()
        migrateThinkingLevels()
        return true
    }

    /// 重命名方案。
    @discardableResult
    func renameProfile(from old: String, to new: String) -> Bool {
        guard let source = profileURL(for: old),
              let target = profileURL(for: new),
              source.path != target.path,
              FileManager.default.fileExists(atPath: source.path) else { return false }
        do {
            try FileManager.default.moveItem(at: source, to: target)
            return true
        } catch {
            return false
        }
    }

    /// 删除方案。
    func deleteProfile(named name: String) {
        guard let url = profileURL(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 导出一个方案到指定位置。
    @discardableResult
    func exportProfile(named name: String, to url: URL) -> Bool {
        guard let source = profileURL(for: name) else { return false }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
            return true
        } catch {
            return false
        }
    }

    /// 从文件导入方案（校验为合法配置后写入方案目录）。
    @discardableResult
    func importProfile(from url: URL, as name: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode(AppSettings.self, from: data)) != nil,
              let target = profileURL(for: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name)
        else { return false }
        do {
            try FileManager.default.createDirectory(atPath: Self.profilesDirectory,
                                                   withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 完整配置导出 / 导入（直接读写 config.json 的内容）

    /// 导出当前完整配置（含 API Key）。
    func exportSettings() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(settings)
    }

    /// 导入完整配置，成功则替换当前设置（旧格式会自动迁移）。
    @discardableResult
    func importSettings(from data: Data) -> Bool {
        guard let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return false }
        settings = s
        migrateLegacyModelData()
        migrateThinkingLevels()
        return true
    }

    // MARK: - 私有辅助

    /// 方案快照：完整设置，去掉旧的模型档案 / 模型列表。
    private func profileSnapshot() -> AppSettings {
        var snapshot = settings
        snapshot.modelProfiles = []
        snapshot.modelList = []
        return snapshot
    }

    /// 方案名 → 文件 URL（过滤路径分隔符等非法字符）。
    private func profileURL(for name: String) -> URL? {
        let cleaned = sanitizeProfileName(name)
        guard !cleaned.isEmpty else { return nil }
        return URL(fileURLWithPath: Self.profilesDirectory)
            .appendingPathComponent(cleaned)
            .appendingPathExtension("json")
    }

    private func sanitizeProfileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        return trimmed.components(separatedBy: invalid).joined(separator: "-")
    }
}
