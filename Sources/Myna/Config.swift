import Foundation

/// 全部可配置项。缺字段时用默认值，保证向后兼容。
struct AppSettings: Codable, Equatable, Sendable {
    // MARK: 模型 / 生成参数
    var baseURL = "https://api.deepseek.com"
    var apiKey = ""
    var model = "deepseek-flash"
    /// 接口类型（协议）：openai-completions / openai-responses / anthropic-messages / google-generative-ai
    var api = "openai-completions"
    /// openai-responses 的推理强度（空 = 关闭）：minimal/low/medium/high/xhigh/max
    var reasoningEffort = ""
    /// anthropic-messages / google-generative-ai 的思考预算（tokens，0 = 关闭）
    var thinkingBudget = 0
    /// 最近使用过的模型（用于快捷切换）
    var recentModels: [String] = []
    /// 供应商列表：每个供应商自带协议 / 地址 / Key 与模型列表
    var providers: [Provider] = []
    /// 当前选中的供应商 / 模型（扁平字段仍是当前生效的配置）
    var activeProviderID: UUID?
    var activeModelID: UUID?
    /// 旧版模型列表（仅用于迁移，迁移后写回空数组）
    var modelList: [String] = []
    /// 旧版模型档案（仅用于迁移，迁移后写回空数组）
    var modelProfiles: [ModelProfile] = []
    var maxTokens = 8192
    var temperature = 0.7
    var topP = 1.0
    var frequencyPenalty = 0.0
    var presencePenalty = 0.0
    var maxRetries = 2
    /// 每次提问的最大工具执行轮数（0 = 不限制）
    var maxToolRounds = 8
    /// 打开后忽略 `maxToolRounds`，工具轮数不设上限
    var unlimitedToolRounds = false

    // MARK: 子agent
    /// 单个子代理一次执行的超时时间（秒）
    var subagentTimeoutSeconds = 300
    /// 子代理最大工具执行轮数
    var subagentMaxRounds = 16
    /// `run_subagents` 同时运行的子代理数量上限
    var subagentMaxParallel = 3
    /// 子代理使用的供应商 / 模型；两者均为空时跟随主模型
    var subagentProviderID: UUID?
    var subagentModelID: UUID?
    /// 打开后忽略 `subagentMaxRounds`，子代理工具轮数使用内部安全上限
    var subagentUnlimitedRounds = false
    /// 打开后忽略 `subagentTimeoutSeconds`，子代理超时使用内部安全上限
    var subagentUnlimitedTimeout = false
    /// 允许子代理再派生子代理（默认关闭，防止递归与费用失控）
    var subagentAllowRecursion = false

    // MARK: 编码 / 文件工具
    /// 文件工具的默认工作目录（空 = 用户主目录）
    var workingDirectory = ""
    /// 编码模式：向系统提示词追加编码专用说明
    var codingMode = false
    /// read_file / search_text 单文件读取的最大字节数
    var maxReadBytes = 1_048_576
    /// run_command 默认超时秒数
    var commandTimeoutSeconds = 120
    /// run_command 与工具输出返回给模型的最大字符数
    var maxOutputChars = 20_000
    /// 危险工具需用户确认（开启后危险工具直接拒绝执行，需关闭后重试）
    var confirmDangerousTools = false

    var systemPrompt = AppSettings.defaultSystemPrompt

    /// PiAgentCore 把 `maxToolRounds == 0` 当作「不执行工具」，
    /// 因此「不限制」在传给 Agent 时用一个足够大的上限表示。
    static let unlimitedToolRoundCap = 10_000

    /// 实际传给 Agent 的工具轮数上限；`maxToolRounds == 0` 或开启
    /// 「无限轮数」时返回 ``unlimitedToolRoundCap``。
    var effectiveMaxToolRounds: Int {
        (unlimitedToolRounds || maxToolRounds == 0) ? AppSettings.unlimitedToolRoundCap : maxToolRounds
    }

    /// 「无限」时的历史轮数上限：足够大，等价于不裁剪，同时避免无界循环。
    static let unlimitedHistoryTurnCap = 10_000

    /// 实际保留的历史对话轮数；`maxHistoryTurns == 0` 或开启「无限」时返回上限。
    var effectiveMaxHistoryTurns: Int {
        (unlimitedHistoryTurns || maxHistoryTurns == 0) ? AppSettings.unlimitedHistoryTurnCap : maxHistoryTurns
    }

    /// 子代理超时安全上限（秒）：即使勾选「不限制」也不会真正无限等待。
    static let unlimitedSubagentTimeoutCap: TimeInterval = 86_400

    /// 子代理实际轮数上限（无请求覆盖时）；「无限制」或设置值 <= 0 使用安全上限。
    var effectiveSubagentMaxRounds: Int {
        (subagentUnlimitedRounds || subagentMaxRounds <= 0)
            ? AppSettings.unlimitedToolRoundCap : subagentMaxRounds
    }

    /// 子代理实际超时（秒）；「无限制」或设置值 <= 0 使用安全上限。
    var effectiveSubagentTimeout: TimeInterval {
        (subagentUnlimitedTimeout || subagentTimeoutSeconds <= 0)
            ? AppSettings.unlimitedSubagentTimeoutCap
            : min(max(Double(subagentTimeoutSeconds), 5), AppSettings.unlimitedSubagentTimeoutCap)
    }

    /// 子代理实际使用的供应商 / 模型设置；未指定或已失效时回退主模型。
    func subagentModelSettings() -> AppSettings {
        var copy = self
        guard let pid = subagentProviderID,
              let provider = providers.first(where: { $0.id == pid }),
              let mid = subagentModelID,
              let entry = provider.models.first(where: { $0.id == mid }) else {
            return copy
        }
        copy.api = provider.api
        copy.baseURL = provider.baseURL
        copy.apiKey = provider.apiKey
        copy.model = entry.name
        copy.reasoningEffort = entry.reasoningEffort
        copy.thinkingBudget = entry.resolvedBudget(forAPI: provider.api)
        if entry.maxTokens > 0 { copy.maxTokens = entry.maxTokens }
        if entry.temperature >= 0 { copy.temperature = entry.temperature }
        return copy
    }

    // MARK: 语音输出
    var voiceEnabled = true
    var voiceLanguage = "zh-CN"
    var voiceName = ""
    var voiceRate = 0.5
    var voiceVolume = 1.0
    var voicePitch = 1.0
    /// 工具执行结果也朗读出来
    var speakToolResults = false

    // MARK: 语音输入
    var silenceTimeout = 1.5
    var noSpeechTimeout = 8.0
    var autoSendOnSilence = false
    var continuousMode = false
    /// 开始/结束录音时播放提示音
    var listenSound = true
    /// 再次按快捷键结束录音时，直接发送
    var hotkeyAutoSend = true

    // MARK: 外观
    /// system / light / dark
    var appearance = "system"
    /// blue / purple / pink / red / orange / yellow / green / graphite
    var accent = "blue"
    var fontSize = 13.0
    /// compact / comfortable
    var density = "comfortable"
    var showTimestamps = false
    var showAvatars = true
    var markdownEnabled = true
    var windowOpacity = 1.0
    var bubbleCornerRadius = 12.0
    var windowWidth = 480.0
    var windowHeight = 700.0

    // MARK: 对话
    var showToolCalls = true
    /// 显示工具执行结果（与调用分开）
    var showToolResults = true
    /// 显示错误消息
    var showErrors = true
    /// 显示思考（reasoning）内容
    var showThinking = true
    /// 思考区块默认收起
    var collapseThinking = true
    /// 工具区块默认收起
    var collapseTools = true
    /// true=回车发送，false=⌘回车发送
    var sendOnEnter = true
    var autoScroll = true
    /// 发送给模型的最近对话轮数上限（0 = 不限制）
    var maxHistoryTurns = 20
    /// 打开后忽略 `maxHistoryTurns`，历史轮数不设上限
    var unlimitedHistoryTurns = false
    /// 关闭窗口时清空对话
    var clearOnClose = false
    /// 切换会话时让后台会话继续运行（关闭则沿用旧行为：切换即取消）
    var backgroundRuns = true
    /// 同时运行的会话数量上限；超出时淘汰最旧的运行
    var maxParallelRuns = 3

    // MARK: 行为
    var hotkey = "option+space"
    /// 下拉面板模式：贴顶向下展开、失焦自动关闭
    var panelMode = true
    /// toggle / pushToTalk
    var hotkeyMode = "toggle"
    /// 只打开窗口（不开始聆听）
    var hotkeyOpen = ""
    /// 清空对话
    var hotkeyClear = ""
    var alwaysOnTop = false
    var launchAtLogin = true
    var showInDock = false
    var menuBarIcon = "custom"
    /// 菜单栏图标高度（pt）
    var menuBarIconSize = 15.0
    /// 面板模式下是否允许拖拽调整尺寸
    var resizablePanel = true
    /// auto / package / builtin
    var agentRuntime = "auto"
    var disabledTools: [String] = []

    static let defaultSystemPrompt = """
    你是运行在 Mac 上的菜单栏助手「Myna」，既可以直接对话，也能通过工具帮用户操作本机。
    规则：
    1. 需要操作本机或获取实时信息时，先调用相应工具，再依据返回结果简短作答；否则直接回答。
    2. 缺少必要参数时先询问用户，不要自行猜测。
    3. 删除文件、关机、清空剪贴板等危险操作执行前先取得用户确认。
    4. 回复简洁自然，适合语音朗读，避免 Markdown 表格、代码块与多余 emoji。
    5. 可按需使用技能、MCP 与编码工具；不确定或执行失败时如实说明，不要编造结果。
    """

    init() {}

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", apiKey = "api_key", model
        case api
        case reasoningEffort = "reasoning_effort"
        case thinkingBudget = "thinking_budget"
        case recentModels = "recent_models"
        case providers
        case activeProviderID = "active_provider_id"
        case activeModelID = "active_model_id"
        case modelList = "model_list"
        case modelProfiles = "model_profiles"
        case maxTokens = "max_tokens", temperature
        case topP = "top_p", frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty", maxRetries = "max_retries"
        case maxToolRounds = "max_tool_rounds"
        case unlimitedToolRounds = "unlimited_tool_rounds"
        case subagentTimeoutSeconds = "subagent_timeout_seconds"
        case subagentMaxRounds = "subagent_max_rounds"
        case subagentMaxParallel = "subagent_max_parallel"
        case subagentProviderID = "subagent_provider_id"
        case subagentModelID = "subagent_model_id"
        case subagentUnlimitedRounds = "subagent_unlimited_rounds"
        case subagentUnlimitedTimeout = "subagent_unlimited_timeout"
        case subagentAllowRecursion = "subagent_allow_recursion"
        case workingDirectory = "working_directory"
        case codingMode = "coding_mode"
        case maxReadBytes = "max_read_bytes"
        case commandTimeoutSeconds = "command_timeout_seconds"
        case maxOutputChars = "max_output_chars"
        case confirmDangerousTools = "confirm_dangerous_tools"
        case systemPrompt = "system_prompt"

        case voiceEnabled = "voice_enabled", voiceLanguage = "voice_language"
        case voiceName = "voice_name", voiceRate = "voice_rate", voiceVolume = "voice_volume"
        case voicePitch = "voice_pitch", speakToolResults = "speak_tool_results"

        case silenceTimeout = "silence_timeout", noSpeechTimeout = "no_speech_timeout"
        case autoSendOnSilence = "auto_send_on_silence", continuousMode = "continuous_mode"
        case listenSound = "listen_sound", hotkeyAutoSend = "hotkey_auto_send"

        case appearance, accent, fontSize = "font_size", density
        case showTimestamps = "show_timestamps", showAvatars = "show_avatars"
        case markdownEnabled = "markdown_enabled", windowOpacity = "window_opacity"
        case bubbleCornerRadius = "bubble_corner_radius"
        case windowWidth = "window_width", windowHeight = "window_height"

        case showToolCalls = "show_tool_calls", sendOnEnter = "send_on_enter"
        case showToolResults = "show_tool_results", showErrors = "show_errors"
        case showThinking = "show_thinking", collapseThinking = "collapse_thinking"
        case collapseTools = "collapse_tools"
        case autoScroll = "auto_scroll", maxHistoryTurns = "max_history_turns"
        case unlimitedHistoryTurns = "unlimited_history_turns"
        case clearOnClose = "clear_on_close"
        case backgroundRuns = "background_runs", maxParallelRuns = "max_parallel_runs"

        case hotkey, alwaysOnTop = "always_on_top", launchAtLogin = "launch_at_login"
        case hotkeyOpen = "hotkey_open", hotkeyClear = "hotkey_clear"
        case hotkeyMode = "hotkey_mode"
        case panelMode = "panel_mode"
        case showInDock = "show_in_dock", menuBarIcon = "menu_bar_icon"
        case menuBarIconSize = "menu_bar_icon_size", resizablePanel = "resizable_panel"
        case agentRuntime = "agent_runtime", disabledTools = "disabled_tools"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys, _ d: String) -> String { (try? c.decode(String.self, forKey: k)) ?? d }
        func int(_ k: CodingKeys, _ d: Int) -> Int { (try? c.decode(Int.self, forKey: k)) ?? d }
        func dbl(_ k: CodingKeys, _ d: Double) -> Double { (try? c.decode(Double.self, forKey: k)) ?? d }
        func bool(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decode(Bool.self, forKey: k)) ?? d }

        // 模型
        baseURL = str(.baseURL, "https://api.deepseek.com")
        apiKey = str(.apiKey, "")
        model = str(.model, "deepseek-flash")
        api = str(.api, "openai-completions")
        reasoningEffort = str(.reasoningEffort, "")
        thinkingBudget = int(.thinkingBudget, 0)
        recentModels = (try? c.decode([String].self, forKey: .recentModels)) ?? []
        providers = (try? c.decode([Provider].self, forKey: .providers)) ?? []
        activeProviderID = try? c.decode(UUID.self, forKey: .activeProviderID)
        activeModelID = try? c.decode(UUID.self, forKey: .activeModelID)
        modelList = (try? c.decode([String].self, forKey: .modelList)) ?? []
        modelProfiles = (try? c.decode([ModelProfile].self, forKey: .modelProfiles)) ?? []
        maxTokens = int(.maxTokens, 8192)
        temperature = dbl(.temperature, 0.7)
        topP = dbl(.topP, 1.0)
        frequencyPenalty = dbl(.frequencyPenalty, 0.0)
        presencePenalty = dbl(.presencePenalty, 0.0)
        maxRetries = int(.maxRetries, 2)
        maxToolRounds = int(.maxToolRounds, 8)
        unlimitedToolRounds = bool(.unlimitedToolRounds, false)
        subagentTimeoutSeconds = int(.subagentTimeoutSeconds, 300)
        subagentMaxRounds = int(.subagentMaxRounds, 16)
        subagentMaxParallel = int(.subagentMaxParallel, 3)
        subagentProviderID = try? c.decode(UUID.self, forKey: .subagentProviderID)
        subagentModelID = try? c.decode(UUID.self, forKey: .subagentModelID)
        subagentUnlimitedRounds = bool(.subagentUnlimitedRounds, false)
        subagentUnlimitedTimeout = bool(.subagentUnlimitedTimeout, false)
        subagentAllowRecursion = bool(.subagentAllowRecursion, false)
        workingDirectory = str(.workingDirectory, "")
        codingMode = bool(.codingMode, false)
        maxReadBytes = int(.maxReadBytes, 1_048_576)
        commandTimeoutSeconds = int(.commandTimeoutSeconds, 120)
        maxOutputChars = int(.maxOutputChars, 20_000)
        confirmDangerousTools = bool(.confirmDangerousTools, false)
        systemPrompt = str(.systemPrompt, AppSettings.defaultSystemPrompt)

        // 语音输出
        voiceEnabled = bool(.voiceEnabled, true)
        voiceLanguage = str(.voiceLanguage, "zh-CN")
        voiceName = str(.voiceName, "")
        voiceRate = dbl(.voiceRate, 0.5)
        voiceVolume = dbl(.voiceVolume, 1.0)
        voicePitch = dbl(.voicePitch, 1.0)
        speakToolResults = bool(.speakToolResults, false)

        // 语音输入
        silenceTimeout = dbl(.silenceTimeout, 1.5)
        noSpeechTimeout = dbl(.noSpeechTimeout, 8.0)
        autoSendOnSilence = bool(.autoSendOnSilence, false)
        continuousMode = bool(.continuousMode, false)
        listenSound = bool(.listenSound, true)
        hotkeyAutoSend = bool(.hotkeyAutoSend, true)

        // 外观
        appearance = str(.appearance, "system")
        accent = str(.accent, "blue")
        fontSize = dbl(.fontSize, 13.0)
        density = str(.density, "comfortable")
        showTimestamps = bool(.showTimestamps, false)
        showAvatars = bool(.showAvatars, true)
        markdownEnabled = bool(.markdownEnabled, true)
        windowOpacity = dbl(.windowOpacity, 1.0)
        bubbleCornerRadius = dbl(.bubbleCornerRadius, 12.0)
        windowWidth = dbl(.windowWidth, 480.0)
        windowHeight = dbl(.windowHeight, 700.0)

        // 对话
        showToolCalls = bool(.showToolCalls, true)
        showToolResults = bool(.showToolResults, true)
        showErrors = bool(.showErrors, true)
        showThinking = bool(.showThinking, true)
        collapseThinking = bool(.collapseThinking, true)
        collapseTools = bool(.collapseTools, true)
        sendOnEnter = bool(.sendOnEnter, true)
        autoScroll = bool(.autoScroll, true)
        maxHistoryTurns = int(.maxHistoryTurns, 20)
        unlimitedHistoryTurns = bool(.unlimitedHistoryTurns, false)
        clearOnClose = bool(.clearOnClose, false)
        backgroundRuns = bool(.backgroundRuns, true)
        maxParallelRuns = int(.maxParallelRuns, 3)

        // 行为
        hotkey = str(.hotkey, "option+space")
        hotkeyMode = str(.hotkeyMode, "toggle")
        panelMode = bool(.panelMode, true)
        hotkeyOpen = str(.hotkeyOpen, "")
        hotkeyClear = str(.hotkeyClear, "")
        alwaysOnTop = bool(.alwaysOnTop, false)
        launchAtLogin = bool(.launchAtLogin, true)
        showInDock = bool(.showInDock, false)
        menuBarIcon = str(.menuBarIcon, "custom")
        menuBarIconSize = dbl(.menuBarIconSize, 15.0)
        resizablePanel = bool(.resizablePanel, true)
        agentRuntime = str(.agentRuntime, "auto")
        // 兼容旧配置：pi 运行时（Node 子进程）已由内建 Swift 包取代
        if agentRuntime == "pi" { agentRuntime = "package" }
        disabledTools = (try? c.decode([String].self, forKey: .disabledTools)) ?? []
    }
}

/// 配置读写（~/.config/myna/config.json），改动后防抖存盘。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }
    let path: String
    private var pendingSave: DispatchWorkItem?
    private var suppressSave = false

    private init() {
        path = NSString(string: "~/.config/myna/config.json").expandingTildeInPath
        let legacy = NSString(string: "~/.config/aisiri/config.json").expandingTildeInPath
        let fm = FileManager.default
        // 从旧版 AiSiri 迁移配置（仅一次，不覆盖新配置）
        if !fm.fileExists(atPath: path), fm.fileExists(atPath: legacy),
           let data = fm.contents(atPath: legacy) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: data)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        if let data = fm.contents(atPath: path),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        // 环境变量覆盖（便于 CLI / CI），不写回配置文件
        suppressSave = true
        applyEnvironmentOverrides()
        suppressSave = false
        // 旧配置迁移：model_profiles / model_list → providers / models（立即落盘）
        suppressSave = true
        let migratedLegacy = migrateLegacyModelData()
        let migratedThinking = migrateThinkingLevels()
        suppressSave = false
        if migratedLegacy || migratedThinking { writeToDisk() }
    }

    private func applyEnvironmentOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let v = env["MYNA_BASE_URL"], !v.isEmpty { settings.baseURL = v }
        if let v = env["MYNA_MODEL"], !v.isEmpty { settings.model = v }
        if let v = env["DEEPSEEK_API_KEY"], !v.isEmpty { settings.apiKey = v }
    }

    /// 防抖保存：拖动滑块 / 连续输入时避免每次改动都写盘。
    private func scheduleSave() {
        guard !suppressSave else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// 立即写盘（退出前调用，避免丢掉未落盘的改动）。
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
    }

    private func writeToDisk() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        FileManager.default.createFile(atPath: path, contents: data)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func reset() {
        settings = AppSettings()
        // 恢复默认设置后补一个与默认扁平字段一致的供应商，避免列表为空。
        migrateLegacyModelData()
        migrateThinkingLevels()
    }
}
