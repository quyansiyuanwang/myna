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
    /// 已保存的多模型配置（扁平字段始终是当前生效的配置）
    var modelProfiles: [ModelProfile] = []
    /// 当前关联的模型配置 id（nil 表示未关联任何已保存配置）
    var activeProfileID: UUID?
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

    var systemPrompt = AppSettings.defaultSystemPrompt

    /// PiAgentCore 把 `maxToolRounds == 0` 当作「不执行工具」，
    /// 因此「不限制」在传给 Agent 时用一个足够大的上限表示。
    static let unlimitedToolRoundCap = 10_000

    /// 实际传给 Agent 的工具轮数上限；`maxToolRounds == 0` 或开启
    /// 「无限轮数」时返回 ``unlimitedToolRoundCap``。
    var effectiveMaxToolRounds: Int {
        (unlimitedToolRounds || maxToolRounds == 0) ? AppSettings.unlimitedToolRoundCap : maxToolRounds
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
    你是运行在用户 Mac 上的智能助手「Myna」。你既可以正常聊天，也可以通过工具操作这台电脑。
    规则：
    1. 用户要求操作电脑（打开/关闭应用、控制音乐、音量、提醒、日历、运行快捷指令、执行 AppleScript、查询电池/时间/剪贴板等）时，先调用相应工具，再根据工具返回结果用简短中文回复。
    2. 涉及需要用户提供但缺失的参数时，先询问用户，不要瞎猜。
    3. 执行危险操作（删除文件、关机、清空剪贴板等）前先确认。
    4. 回复简洁自然，适合语音朗读（不要用 Markdown 表格、代码块、过多 emoji）。
    5. 不确定时如实说明，不要编造工具执行结果。
    """

    init() {}

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", apiKey = "api_key", model
        case api
        case reasoningEffort = "reasoning_effort"
        case thinkingBudget = "thinking_budget"
        case recentModels = "recent_models"
        case modelProfiles = "model_profiles"
        case activeProfileID = "active_profile_id"
        case maxTokens = "max_tokens", temperature
        case topP = "top_p", frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty", maxRetries = "max_retries"
        case maxToolRounds = "max_tool_rounds"
        case unlimitedToolRounds = "unlimited_tool_rounds"
        case subagentTimeoutSeconds = "subagent_timeout_seconds"
        case subagentMaxRounds = "subagent_max_rounds"
        case subagentMaxParallel = "subagent_max_parallel"
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
        modelProfiles = (try? c.decode([ModelProfile].self, forKey: .modelProfiles)) ?? []
        activeProfileID = try? c.decode(UUID.self, forKey: .activeProfileID)
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

    func reset() { settings = AppSettings() }
}
