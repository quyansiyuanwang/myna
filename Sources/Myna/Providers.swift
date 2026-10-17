import Foundation

// MARK: - 数据模型

/// 一个模型条目。
///
/// `name` 是发送给接口的模型 id；其余字段保存**该模型自己**的参数，
/// 这样切换模型时推理与采样设置可以一并切换。
struct ModelEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// 发送给接口的模型 id
    var name: String
    /// 界面显示名；为空时退回 `name`
    var displayName: String
    /// openai-responses 的推理强度（空 = 关闭）
    var reasoningEffort: String
    /// anthropic-messages / google-generative-ai 的思考预算（tokens，0 = 关闭）
    var thinkingBudget: Int
    /// 单次输出上限（0 = 沿用全局设置）
    var maxTokens: Int
    /// 温度（< 0 = 沿用全局设置）
    var temperature: Double
    /// 上下文窗口（0 = 未知）
    var contextWindow: Int
    /// 是否由端点探测得到
    var discovered: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        displayName: String = "",
        reasoningEffort: String = "",
        thinkingBudget: Int = 0,
        maxTokens: Int = 0,
        temperature: Double = -1,
        contextWindow: Int = 0,
        discovered: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.reasoningEffort = reasoningEffort
        self.thinkingBudget = thinkingBudget
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.contextWindow = contextWindow
        self.discovered = discovered
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case displayName = "display_name"
        case reasoningEffort = "reasoning_effort"
        case thinkingBudget = "thinking_budget"
        case maxTokens = "max_tokens"
        case temperature
        case contextWindow = "context_window"
        case discovered
    }

    /// 逐字段解码并提供默认值，手写或旧版 JSON 缺字段时仍可读取。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys, _ d: String) -> String { (try? c.decode(String.self, forKey: k)) ?? d }
        func int(_ k: CodingKeys, _ d: Int) -> Int { (try? c.decode(Int.self, forKey: k)) ?? d }

        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = str(.name, "")
        displayName = str(.displayName, "")
        reasoningEffort = str(.reasoningEffort, "")
        thinkingBudget = int(.thinkingBudget, 0)
        maxTokens = int(.maxTokens, 0)
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? -1
        contextWindow = int(.contextWindow, 0)
        discovered = (try? c.decode(Bool.self, forKey: .discovered)) ?? false
    }

    /// 界面显示文本。
    var label: String { displayName.isEmpty ? name : displayName }

    /// 推理参数摘要（空串表示该模型没有单独的推理设置）。
    var reasoningSummary: String {
        if !reasoningEffort.isEmpty { return "推理 \(reasoningEffort)" }
        if thinkingBudget > 0 { return "思考 \(thinkingBudget)" }
        return ""
    }
}

/// 一个供应商：自带名称、协议、地址、Key，以及属于它的模型列表。
struct Provider: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// 显示名称，例如「DeepSeek」
    var name: String
    /// 接口类型（协议），取值同 `APIType`。
    var api: String
    var baseURL: String
    var apiKey: String
    var models: [ModelEntry]

    init(
        id: UUID = UUID(),
        name: String = "",
        api: String = APIType.openAICompletions.rawValue,
        baseURL: String = "",
        apiKey: String = "",
        models: [ModelEntry] = []
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case id, name, api
        case baseURL = "base_url"
        case apiKey = "api_key"
        case models
    }

    /// 逐字段解码并提供默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        api = (try? c.decode(String.self, forKey: .api)) ?? APIType.openAICompletions.rawValue
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? ""
        models = (try? c.decode([ModelEntry].self, forKey: .models)) ?? []
    }

    /// 协议短标签（用于列表第二行）。
    var apiLabel: String { APIType.from(api).label }
}

// MARK: - 供应商与模型管理

/// `SettingsStore` 上的供应商 / 模型操作。
///
/// 扁平字段（`baseURL` / `apiKey` / `model` / 推理与采样参数）始终是**当前生效**的配置；
/// 选中供应商或模型时调用 ``SettingsStore/applyActiveSelection()`` 把值写回扁平字段，
/// 因此运行时（`PackageRuntime`、`ChatModel.packageSignatureValue`）无需改动。
extension SettingsStore {

    // MARK: 当前选择

    /// 当前供应商 id：优先按扁平字段（地址 + 协议）匹配，其次用 `active_provider_id`。
    var currentProviderID: UUID? {
        if let p = settings.providers.first(where: { flatFieldsMatch($0) }) { return p.id }
        if let id = settings.activeProviderID, settings.providers.contains(where: { $0.id == id }) {
            return id
        }
        return nil
    }

    /// 当前模型 id：在当前供应商内优先按模型 id 匹配，其次用 `active_model_id`。
    var currentModelID: UUID? {
        guard let pid = currentProviderID,
              let provider = settings.providers.first(where: { $0.id == pid }) else { return nil }
        if let m = provider.models.first(where: { $0.name == settings.model }) { return m.id }
        if let id = settings.activeModelID, provider.models.contains(where: { $0.id == id }) { return id }
        return nil
    }

    /// 当前模型条目。
    var currentModelEntry: ModelEntry? {
        guard let pid = currentProviderID,
              let provider = settings.providers.first(where: { $0.id == pid }),
              let mid = currentModelID else { return nil }
        return provider.models.first(where: { $0.id == mid })
    }

    /// 顶栏 / 状态栏展示的当前模型名。
    var currentModelLabel: String {
        guard let entry = currentModelEntry else { return settings.model }
        return entry.label.isEmpty ? settings.model : entry.label
    }

    /// 把当前选择写入扁平字段（供应商的协议 / 地址 / Key，模型的 id 与参数）。
    ///
    /// 只在**选择变化**时调用；用户直接编辑扁平字段时不会被强行覆盖。
    func applyActiveSelection() {
        guard let pid = settings.activeProviderID,
              let provider = settings.providers.first(where: { $0.id == pid }) else { return }
        settings.api = provider.api
        settings.baseURL = provider.baseURL
        settings.apiKey = provider.apiKey
        guard let mid = settings.activeModelID,
              let entry = provider.models.first(where: { $0.id == mid }) else { return }
        applyModelFields(entry)
    }

    /// 选中某个供应商下的某个模型，并写回扁平字段。
    func selectModel(providerID: UUID, modelID: UUID) {
        guard let provider = settings.providers.first(where: { $0.id == providerID }),
              provider.models.contains(where: { $0.id == modelID }) else { return }
        settings.activeProviderID = providerID
        settings.activeModelID = modelID
        applyActiveSelection()
    }

    /// 把推理参数写回**当前模型**与扁平字段（「推理」分区使用）。
    func updateCurrentReasoning(effort: String? = nil, budget: Int? = nil) {
        if let effort { settings.reasoningEffort = effort }
        if let budget { settings.thinkingBudget = budget }
        guard let pid = currentProviderID, let mid = currentModelID,
              let pi = settings.providers.firstIndex(where: { $0.id == pid }),
              let mi = settings.providers[pi].models.firstIndex(where: { $0.id == mid }) else { return }
        if let effort { settings.providers[pi].models[mi].reasoningEffort = effort }
        if let budget { settings.providers[pi].models[mi].thinkingBudget = budget }
    }

    /// 把当前模型的参数同步到扁平字段（模型编辑器使用）。
    /// 仅当被编辑的是当前模型时才写回，避免误改正在生效的配置。
    func syncCurrentModel(providerID: UUID, modelID: UUID) {
        guard let provider = settings.providers.first(where: { $0.id == providerID }),
              currentProviderID == providerID,
              currentModelID == modelID,
              let entry = provider.models.first(where: { $0.id == modelID }) else { return }
        applyModelFields(entry)
    }

    private func applyModelFields(_ entry: ModelEntry) {
        settings.model = entry.name
        settings.reasoningEffort = entry.reasoningEffort
        settings.thinkingBudget = entry.thinkingBudget
        if entry.maxTokens > 0 { settings.maxTokens = entry.maxTokens }
        if entry.temperature >= 0 { settings.temperature = entry.temperature }
        rememberRecent(entry.name)
    }

    private func flatFieldsMatch(_ provider: Provider) -> Bool {
        provider.api == settings.api && Self.normalizeURL(provider.baseURL) == Self.normalizeURL(settings.baseURL)
    }

    /// 去掉首尾空白与尾部斜杠，便于比较地址。
    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: 供应商

    /// 新建一个空供应商（地址与 Key 由用户填写）。
    @discardableResult
    func addProvider() -> Provider {
        let provider = Provider(name: uniqueProviderName(base: "新供应商"))
        settings.providers.append(provider)
        return provider
    }

    /// 复制供应商（连同它的模型列表）。
    @discardableResult
    func duplicateProvider(id: UUID) -> Provider? {
        guard let source = settings.providers.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueProviderName(base: source.name + " 副本")
        copy.models = source.models.map {
            var m = $0
            m.id = UUID()
            return m
        }
        settings.providers.append(copy)
        return copy
    }

    /// 删除供应商；若删除的是当前供应商，只解除关联（扁平字段保持不变）。
    func deleteProvider(id: UUID) {
        settings.providers.removeAll { $0.id == id }
        if settings.activeProviderID == id {
            settings.activeProviderID = nil
            settings.activeModelID = nil
        }
    }

    /// 重命名供应商。
    func renameProvider(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = settings.providers.firstIndex(where: { $0.id == id }) else { return }
        settings.providers[i].name = trimmed
    }

    /// 记录最近使用的模型（顶栏快捷切换用）。
    func rememberRecent(_ model: String) {
        guard !model.isEmpty else { return }
        var list = settings.recentModels.filter { $0 != model }
        list.insert(model, at: 0)
        settings.recentModels = Array(list.prefix(8))
    }

    // MARK: 模型

    /// 手动添加模型（按模型 id 去重）。
    @discardableResult
    func addModel(named name: String, toProvider providerID: UUID, discovered: Bool = false) -> ModelEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pi = settings.providers.firstIndex(where: { $0.id == providerID }) else { return nil }
        if let mi = settings.providers[pi].models.firstIndex(where: { $0.name == trimmed }) {
            if discovered { settings.providers[pi].models[mi].discovered = true }
            return settings.providers[pi].models[mi]
        }
        let entry = ModelEntry(name: trimmed, discovered: discovered)
        settings.providers[pi].models.append(entry)
        return entry
    }

    /// 把探测结果合并进指定供应商（按模型 id 去重，已有条目也会标记为探测得到），返回新增数量。
    @discardableResult
    func mergeDiscoveredModels(_ names: [String], intoProvider providerID: UUID) -> Int {
        var added = 0
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let pi = settings.providers.firstIndex(where: { $0.id == providerID }) else { continue }
            if let mi = settings.providers[pi].models.firstIndex(where: { $0.name == trimmed }) {
                settings.providers[pi].models[mi].discovered = true
                continue
            }
            settings.providers[pi].models.append(ModelEntry(name: trimmed, discovered: true))
            added += 1
        }
        return added
    }

    /// 复制模型（名称加「副本」）。
    @discardableResult
    func duplicateModel(id: UUID, inProvider providerID: UUID) -> ModelEntry? {
        guard let pi = settings.providers.firstIndex(where: { $0.id == providerID }),
              let mi = settings.providers[pi].models.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = settings.providers[pi].models[mi]
        copy.id = UUID()
        copy.displayName = uniqueModelName(base: copy.label + " 副本",
                                           in: settings.providers[pi].models)
        // 复制出的条目当作手动录入，避免被当作探测结果。
        copy.discovered = false
        settings.providers[pi].models.insert(copy, at: mi + 1)
        return copy
    }

    /// 删除模型。
    func deleteModel(id: UUID, inProvider providerID: UUID) {
        guard let pi = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        settings.providers[pi].models.removeAll { $0.id == id }
        if settings.activeProviderID == providerID, settings.activeModelID == id {
            settings.activeModelID = nil
        }
    }

    // MARK: 迁移

    /// 把旧配置（`model_profiles` + `model_list`）转换成供应商 / 模型，并补全当前选择。
    ///
    /// 规则：
    /// 1. `model_profiles` 按「地址 + 协议」分组为供应商；每组的第一个档案名成为供应商名，
    ///    后续档案名成为对应模型的显示名。
    /// 2. `model_list` 中的模型追加到与当前 `base_url` / `api` 匹配的供应商（必要时新建）。
    /// 3. 若仍没有供应商，则用当前扁平字段创建一个，并保证 `active_provider_id` /
    ///    `active_model_id` 指向与扁平字段一致的条目。
    ///
    /// 迁移完成后 `model_profiles` / `model_list` 会写回空数组（保留解码一个版本）。
    /// - Returns: 是否发生了改动（用于立即落盘）。
    @discardableResult
    func migrateLegacyModelData() -> Bool {
        var changed = false

        if settings.providers.isEmpty {
            // 1. 旧的模型档案 → 供应商
            for profile in settings.modelProfiles {
                let display = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pi = providerIndex(baseURL: profile.baseURL, api: profile.api) {
                    guard !profile.model.isEmpty else { continue }
                    if !settings.providers[pi].models.contains(where: { $0.name == profile.model }) {
                        settings.providers[pi].models.append(ModelEntry(
                            name: profile.model,
                            displayName: display.isEmpty ? profile.model : display,
                            reasoningEffort: profile.reasoningEffort,
                            thinkingBudget: profile.thinkingBudget,
                            maxTokens: profile.maxTokens,
                            temperature: profile.temperature
                        ))
                    }
                } else {
                    var provider = Provider(
                        name: display.isEmpty
                            ? Self.defaultProviderName(baseURL: profile.baseURL, api: profile.api)
                            : display,
                        api: profile.api,
                        baseURL: profile.baseURL,
                        apiKey: profile.apiKey
                    )
                    if !profile.model.isEmpty {
                        provider.models.append(ModelEntry(
                            name: profile.model,
                            displayName: profile.model,
                            reasoningEffort: profile.reasoningEffort,
                            thinkingBudget: profile.thinkingBudget,
                            maxTokens: profile.maxTokens,
                            temperature: profile.temperature
                        ))
                    }
                    settings.providers.append(provider)
                }
                changed = true
            }

            // 2. 旧的模型列表 → 当前地址对应的供应商
            if !settings.modelList.isEmpty {
                let pi = providerIndex(baseURL: settings.baseURL, api: settings.api) ?? {
                    settings.providers.append(Provider(
                        name: uniqueProviderName(base: Self.defaultProviderName(baseURL: settings.baseURL,
                                                                               api: settings.api)),
                        api: settings.api,
                        baseURL: settings.baseURL,
                        apiKey: settings.apiKey
                    ))
                    return settings.providers.count - 1
                }()
                for raw in settings.modelList {
                    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty,
                          !settings.providers[pi].models.contains(where: { $0.name == name }) else { continue }
                    settings.providers[pi].models.append(ModelEntry(name: name))
                }
                changed = true
            }

            if changed {
                settings.modelProfiles = []
                settings.modelList = []
            }
        }

        // 3. 保证至少有一个供应商，且当前选择可用
        if settings.providers.isEmpty {
            var provider = Provider(
                name: uniqueProviderName(base: Self.defaultProviderName(baseURL: settings.baseURL,
                                                                       api: settings.api)),
                api: settings.api,
                baseURL: settings.baseURL,
                apiKey: settings.apiKey
            )
            if !settings.model.isEmpty {
                provider.models.append(ModelEntry(
                    name: settings.model,
                    reasoningEffort: settings.reasoningEffort,
                    thinkingBudget: settings.thinkingBudget,
                    maxTokens: settings.maxTokens,
                    temperature: settings.temperature
                ))
            }
            settings.providers.append(provider)
            changed = true
        }

        if ensureActiveSelection() { changed = true }
        return changed
    }

    /// 补全 `active_provider_id` / `active_model_id`，使其指向与扁平字段一致的条目。
    @discardableResult
    func ensureActiveSelection() -> Bool {
        guard let pi = providerIndex(baseURL: settings.baseURL, api: settings.api)
            ?? settings.providers.indices.first else { return false }
        var changed = false
        let provider = settings.providers[pi]
        if !provider.models.contains(where: { $0.name == settings.model }), !settings.model.isEmpty,
           providerIndex(baseURL: settings.baseURL, api: settings.api) != nil {
            // 当前模型还没有条目：按扁平字段补一条（保留现有参数）。
            settings.providers[pi].models.append(ModelEntry(
                name: settings.model,
                reasoningEffort: settings.reasoningEffort,
                thinkingBudget: settings.thinkingBudget,
                maxTokens: settings.maxTokens,
                temperature: settings.temperature
            ))
            changed = true
        }
        let models = settings.providers[pi].models
        let modelID = models.first(where: { $0.name == settings.model })?.id ?? models.first?.id
        if settings.activeProviderID != settings.providers[pi].id {
            settings.activeProviderID = settings.providers[pi].id
            changed = true
        }
        if settings.activeModelID != modelID {
            settings.activeModelID = modelID
            changed = true
        }
        return changed
    }

    private func providerIndex(baseURL: String, api: String) -> Int? {
        let target = Self.normalizeURL(baseURL)
        return settings.providers.firstIndex {
            $0.api == api && Self.normalizeURL($0.baseURL) == target
        }
    }

    private func uniqueProviderName(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "供应商" : trimmed
        var candidate = seed
        var n = 2
        let existing = Set(settings.providers.map(\.name))
        while existing.contains(candidate) {
            candidate = "\(seed) \(n)"
            n += 1
        }
        return candidate
    }

    private func uniqueModelName(base: String, in models: [ModelEntry]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "模型" : trimmed
        var candidate = seed
        var n = 2
        let existing = Set(models.map(\.label))
        while existing.contains(candidate) {
            candidate = "\(seed) \(n)"
            n += 1
        }
        return candidate
    }

    /// 从地址推导供应商名：`https://api.deepseek.com` → `Deepseek`。
    static func defaultProviderName(baseURL: String, api: String) -> String {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let host = URL(string: raw)?.host, !host.isEmpty else {
            return APIType.from(api).label
        }
        var parts = host.split(separator: ".").map(String.init)
        if parts.first?.lowercased() == "api" { parts.removeFirst() }
        guard let head = parts.first, !head.isEmpty else { return host }
        return head.prefix(1).uppercased() + head.dropFirst()
    }
}
