import Foundation

/// 一个可保存、可切换的模型配置。
///
/// 扁平字段（`AppSettings.baseURL` 等）始终代表**当前生效**的配置；
/// 选中某个配置时把它的值复制到扁平字段，反之编辑扁平字段不会改动已保存的配置。
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

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        model: String = "",
        api: String = APIType.openAICompletions.rawValue,
        reasoningEffort: String = "",
        thinkingBudget: Int = 0,
        maxTokens: Int = 8192,
        temperature: Double = 0.7
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.api = api
        self.reasoningEffort = reasoningEffort
        self.thinkingBudget = thinkingBudget
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

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

// MARK: - 配置读写辅助

/// `SettingsStore` 上的多模型管理操作。
///
/// 所有操作都只改动 `settings`（触发防抖存盘），不会自行重建 Agent；
/// 扁平字段变化后由聊天视图按签名重建。
extension SettingsStore {

    /// 用当前实时配置新建一个配置，并设为当前配置。
    @discardableResult
    func addProfile(from current: AppSettings) -> ModelProfile {
        let profile = ModelProfile(
            name: uniqueProfileName(base: current.model),
            baseURL: current.baseURL,
            apiKey: current.apiKey,
            model: current.model,
            api: current.api,
            reasoningEffort: current.reasoningEffort,
            thinkingBudget: current.thinkingBudget,
            maxTokens: current.maxTokens,
            temperature: current.temperature
        )
        settings.modelProfiles.append(profile)
        settings.activeProfileID = profile.id
        return profile
    }

    /// 用当前实时配置覆盖当前选中的配置；没有选中项时新建一个。
    func updateProfile(from current: AppSettings) {
        guard let id = current.activeProfileID,
              let idx = settings.modelProfiles.firstIndex(where: { $0.id == id }) else {
            _ = addProfile(from: current)
            return
        }
        settings.modelProfiles[idx].baseURL = current.baseURL
        settings.modelProfiles[idx].apiKey = current.apiKey
        settings.modelProfiles[idx].model = current.model
        settings.modelProfiles[idx].api = current.api
        settings.modelProfiles[idx].reasoningEffort = current.reasoningEffort
        settings.modelProfiles[idx].thinkingBudget = current.thinkingBudget
        settings.modelProfiles[idx].maxTokens = current.maxTokens
        settings.modelProfiles[idx].temperature = current.temperature
    }

    /// 删除指定配置；若删除的是当前配置则解除关联（不改动扁平字段）。
    func deleteProfile(id: UUID) {
        settings.modelProfiles.removeAll { $0.id == id }
        if settings.activeProfileID == id { settings.activeProfileID = nil }
    }

    /// 应用指定配置：把它复制到扁平字段并设为当前配置。
    func selectProfile(id: UUID) {
        guard let p = settings.modelProfiles.first(where: { $0.id == id }) else { return }
        settings.baseURL = p.baseURL
        settings.apiKey = p.apiKey
        settings.model = p.model
        settings.api = p.api
        settings.reasoningEffort = p.reasoningEffort
        settings.thinkingBudget = p.thinkingBudget
        settings.maxTokens = p.maxTokens
        settings.temperature = p.temperature
        settings.activeProfileID = p.id
        rememberRecent(p.model)
    }

    /// 复制指定配置为一份副本并追加到列表末尾（不改变当前配置）。
    func duplicateProfile(id: UUID) {
        guard let p = settings.modelProfiles.first(where: { $0.id == id }) else { return }
        var copy = p
        copy.id = UUID()
        copy.name = uniqueProfileName(base: p.name + " 副本")
        settings.modelProfiles.append(copy)
    }

    /// 记录最近使用的模型（顶栏快捷切换用）。
    func rememberRecent(_ model: String) {
        guard !model.isEmpty else { return }
        var list = settings.recentModels.filter { $0 != model }
        list.insert(model, at: 0)
        settings.recentModels = Array(list.prefix(8))
    }

    private func uniqueProfileName(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "配置" : trimmed
        var candidate = seed
        var n = 2
        let existing = Set(settings.modelProfiles.map(\.name))
        while existing.contains(candidate) {
            candidate = "\(seed) \(n)"
            n += 1
        }
        return candidate
    }
}
