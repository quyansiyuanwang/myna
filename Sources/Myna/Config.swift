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

    // MARK: 电脑操作 / 自我管理
    /// 允许读取屏幕（截图 / OCR / 窗口列表）。
    var screenAccessEnabled = true
    /// 允许控制鼠标与键盘。
    var computerControlEnabled = true
    /// 截图后自动做 OCR，让纯文本模型也能「看」界面。
    var screenOCREnabled = true
    /// 当前模型是否支持图片输入（决定是否把视图声明为 text + image）。
    var supportsVision = false

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
        copy.supportsVision = entry.supportsVision
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
    /// 发送给模型的最近对话轮数上限（0 = 不限制）。
    ///
    /// 默认不裁剪：删掉最早的用户轮次会让请求前缀从被删位置起变化，
    /// 服务端前缀缓存随之失效；完整历史 + 缓存比裁剪更省。
    var maxHistoryTurns = 0
    /// 打开后忽略 `maxHistoryTurns`，历史轮数不设上限
    var unlimitedHistoryTurns = false
    /// 历史默认值迁移是否已执行（旧默认 20 → 0）；避免每次启动都把 20 改回来。
    var historyDefaultMigrated = true
    /// 关闭窗口时清空对话
    var clearOnClose = false
    /// 切换会话时让后台会话继续运行（关闭则沿用旧行为：切换即取消）
    var backgroundRuns = true
    /// 同时运行的会话数量上限；超出时淘汰最旧的运行
    var maxParallelRuns = 3
    /// 新会话的默认模式：normal / plan / goal / create
    var defaultMode = ChatMode.normal.rawValue

    // MARK: 上下文压缩
    /// 接近上下文预算时自动压缩旧轮次。
    var autoCompact = true
    /// 触发阈值（有效提示词预算的百分比）。
    var compactThresholdPercent = 75
    /// 压缩后保留的最近用户轮数。
    var compactKeepTurns = 6
    /// 摘要输出上限（tokens）。
    var compactMaxTokens = 1_200

    // MARK: 目标模式
    /// 目标模式下自动续跑。
    var goalAutoContinue = true
    /// 单个目标最多自动续跑轮数。
    var goalMaxIterations = 8

    // MARK: 权限
    /// 工具名 -> allow / ask / deny；缺省按工具风险与当前模式决定。
    var toolPolicies: [String: String] = [:]
    /// 权限弹窗超时（秒）；超时按拒绝处理。
    var permissionPromptTimeoutSeconds = 120

    // MARK: 附件
    /// 单条消息最多附加多少个文件/文件夹。
    var attachmentMaxItems = 10
    /// 小文本文件内联到提示词的总字符上限。
    var attachmentInlineChars = 24_000

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

    // MARK: 网络搜索
    /// 搜索服务商：none / tavily / brave / serper / custom
    var searchProvider = "none"
    var searchApiKey = ""
    /// 自定义服务商接口地址；含 `{query}` 时改用 GET 并在该占位符处拼接关键词
    var searchBaseURL = ""
    /// 每次搜索返回的结果条数（1…20）
    var searchMaxResults = 5
    /// 搜索请求超时（秒，3…60）
    var searchTimeoutSeconds = 15
    /// 是否请求服务商返回综合答案（Tavily 支持）
    var searchIncludeAnswer = false

    /// 归一化后的结果条数。
    var effectiveSearchMaxResults: Int { min(max(searchMaxResults, 1), 20) }

    /// 归一化后的搜索超时（秒）。
    var effectiveSearchTimeout: TimeInterval { TimeInterval(min(max(searchTimeoutSeconds, 3), 60)) }

    // MARK: 网络代理
    var proxyEnabled = false
    /// http / https / socks5
    var proxyType = "http"
    var proxyHost = ""
    var proxyPort = 0
    var proxyUsername = ""
    var proxyPassword = ""
    /// 绕过代理的主机列表（逗号或空白分隔）
    var proxyBypass = ""

    // MARK: 更新
    /// 合并连续的思考块为一个可折叠分组
    /// 社区仓库来源（可多个）。默认只带作者的 Myna Hub，可增删，安装时按条目回到各自来源。
    var hubSources: [HubSource] = [.defaultMynaHub]

    /// 把思考与工具调用合并成**一个**分组（DeepSeek Harness 的处理过程形态）。
    var mergeProcessingBlocks = true
    var mergeThinkingBlocks = true
    /// 合并连续的工具调用与结果为一个可折叠分组
    var mergeToolBlocks = true
    /// 对话完成后自动收起处理过程，只留最终回复
    var collapseProcessingAfterRun = true

    // MARK: 性能
    /// 关闭阴影与过渡动画（低功耗机器的首选）。
    var reduceVisualEffects = false
    /// 流式期间用纯文本渲染，结束后再渲染 Markdown。
    var streamPlainText = false
    /// 超长消息（>3000 字）折叠为预览。**默认关闭**：
    /// 正常消息应完整显示，需要极限性能时再打开。
    var collapseLongMessages = false
    /// 消息列表最多渲染多少条（0 = 全部）。超出部分折叠为「显示更早的消息」。
    var maxRenderedMessages = 0
    /// 后台会话完成时发送系统通知
    var backgroundNotifications = true

    // MARK: 费用保护
    /// 单轮提问最多发出多少次模型请求（一次工具往返算一次）；0 = 不限制。
    var maxRequestsPerRun = 40
    /// 单次请求的提示词上限（估算值，含工具 Schema）；0 = 不限制。
    var maxPromptTokens = 128_000
    /// 每天允许 Myna 消耗的 token 总量；0 = 不限制。跨天自动归零。
    var dailyTokenBudget = 0
    /// 每天允许 Myna 花费的人民币金额；0 = 不限制。
    var dailyCostBudget: Double = 0
    /// 模型名 -> 单价覆盖；为空时使用内置 DeepSeek 价格表。
    var modelPrices: [String: ModelPrice] = [:]

    /// 启动时自动检查更新（最多每 24 小时一次）
    var autoCheckUpdates = true
    /// 上次检查更新的 Unix 时间戳（秒）；用于把自动检查节流到 24 小时一次
    var lastUpdateCheck = 0.0

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
        case screenAccessEnabled = "screen_access_enabled"
        case computerControlEnabled = "computer_control_enabled"
        case screenOCREnabled = "screen_ocr_enabled"
        case supportsVision = "supports_vision"

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
        case historyDefaultMigrated = "history_default_migrated"
        case clearOnClose = "clear_on_close"
        case backgroundRuns = "background_runs", maxParallelRuns = "max_parallel_runs"
        case defaultMode = "default_mode"
        case autoCompact = "auto_compact"
        case compactThresholdPercent = "compact_threshold_percent"
        case compactKeepTurns = "compact_keep_turns"
        case compactMaxTokens = "compact_max_tokens"
        case goalAutoContinue = "goal_auto_continue"
        case goalMaxIterations = "goal_max_iterations"
        case toolPolicies = "tool_policies"
        case permissionPromptTimeoutSeconds = "permission_prompt_timeout_seconds"
        case attachmentMaxItems = "attachment_max_items"
        case attachmentInlineChars = "attachment_inline_chars"

        case hotkey, alwaysOnTop = "always_on_top", launchAtLogin = "launch_at_login"
        case hotkeyOpen = "hotkey_open", hotkeyClear = "hotkey_clear"
        case hotkeyMode = "hotkey_mode"
        case panelMode = "panel_mode"
        case showInDock = "show_in_dock", menuBarIcon = "menu_bar_icon"
        case menuBarIconSize = "menu_bar_icon_size", resizablePanel = "resizable_panel"
        case agentRuntime = "agent_runtime", disabledTools = "disabled_tools"

        case searchProvider = "search_provider", searchApiKey = "search_api_key"
        case searchBaseURL = "search_base_url", searchMaxResults = "search_max_results"
        case searchTimeoutSeconds = "search_timeout_seconds"
        case searchIncludeAnswer = "search_include_answer"

        case proxyEnabled = "proxy_enabled", proxyType = "proxy_type"
        case proxyHost = "proxy_host", proxyPort = "proxy_port"
        case proxyUsername = "proxy_username", proxyPassword = "proxy_password"
        case proxyBypass = "proxy_bypass"

        case autoCheckUpdates = "auto_check_updates"
        case backgroundNotifications = "background_notifications"
        case maxRequestsPerRun = "max_requests_per_run"
        case maxPromptTokens = "max_prompt_tokens"
        case dailyTokenBudget = "daily_token_budget"
        case dailyCostBudget = "daily_cost_budget"
        case modelPrices = "model_prices"
        case hubSources = "hub_sources"
        case mergeProcessingBlocks = "merge_processing_blocks"
        case mergeThinkingBlocks = "merge_thinking_blocks"
        case mergeToolBlocks = "merge_tool_blocks"
        case collapseProcessingAfterRun = "collapse_processing_after_run", lastUpdateCheck = "last_update_check"
        case reduceVisualEffects = "reduce_visual_effects"
        case streamPlainText = "stream_plain_text"
        case maxRenderedMessages = "max_rendered_messages"
        case collapseLongMessages = "collapse_long_messages"
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
        screenAccessEnabled = bool(.screenAccessEnabled, true)
        computerControlEnabled = bool(.computerControlEnabled, true)
        screenOCREnabled = bool(.screenOCREnabled, true)
        supportsVision = bool(.supportsVision, false)
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
        maxHistoryTurns = int(.maxHistoryTurns, 0)
        unlimitedHistoryTurns = bool(.unlimitedHistoryTurns, false)
        historyDefaultMigrated = bool(.historyDefaultMigrated, false)
        clearOnClose = bool(.clearOnClose, false)
        backgroundRuns = bool(.backgroundRuns, true)
        maxParallelRuns = int(.maxParallelRuns, 3)
        defaultMode = str(.defaultMode, ChatMode.normal.rawValue)
        autoCompact = bool(.autoCompact, true)
        compactThresholdPercent = min(95, max(40, int(.compactThresholdPercent, 75)))
        compactKeepTurns = max(2, int(.compactKeepTurns, 6))
        compactMaxTokens = max(200, int(.compactMaxTokens, 1_200))
        goalAutoContinue = bool(.goalAutoContinue, true)
        goalMaxIterations = max(1, int(.goalMaxIterations, 8))
        toolPolicies = (try? c.decode([String: String].self, forKey: .toolPolicies)) ?? [:]
        permissionPromptTimeoutSeconds = max(10, int(.permissionPromptTimeoutSeconds, 120))
        attachmentMaxItems = max(1, int(.attachmentMaxItems, 10))
        attachmentInlineChars = max(1_000, int(.attachmentInlineChars, 24_000))

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

        // 网络搜索
        searchProvider = str(.searchProvider, "none")
        searchApiKey = str(.searchApiKey, "")
        searchBaseURL = str(.searchBaseURL, "")
        searchMaxResults = int(.searchMaxResults, 5)
        searchTimeoutSeconds = int(.searchTimeoutSeconds, 15)
        searchIncludeAnswer = bool(.searchIncludeAnswer, false)

        // 网络代理
        proxyEnabled = bool(.proxyEnabled, false)
        proxyType = str(.proxyType, "http")
        proxyHost = str(.proxyHost, "")
        proxyPort = int(.proxyPort, 0)
        proxyUsername = str(.proxyUsername, "")
        proxyPassword = str(.proxyPassword, "")
        proxyBypass = str(.proxyBypass, "")

        // 更新
        autoCheckUpdates = bool(.autoCheckUpdates, true)
        backgroundNotifications = bool(.backgroundNotifications, true)
        maxRequestsPerRun = max(0, int(.maxRequestsPerRun, 40))
        maxPromptTokens = max(0, int(.maxPromptTokens, 128_000))
        dailyTokenBudget = max(0, int(.dailyTokenBudget, 0))
        dailyCostBudget = max(0, dbl(.dailyCostBudget, 0))
        modelPrices = (try? c.decode([String: ModelPrice].self, forKey: .modelPrices)) ?? [:]
        // 缺省时给内置来源；显式空数组表示用户清空了全部来源。
        hubSources = (try? c.decode([HubSource].self, forKey: .hubSources)) ?? [.defaultMynaHub]
        mergeProcessingBlocks = bool(.mergeProcessingBlocks, true)
        mergeThinkingBlocks = bool(.mergeThinkingBlocks, true)
        mergeToolBlocks = bool(.mergeToolBlocks, true)
        collapseProcessingAfterRun = bool(.collapseProcessingAfterRun, true)
        reduceVisualEffects = bool(.reduceVisualEffects, false)
        streamPlainText = bool(.streamPlainText, false)
        maxRenderedMessages = max(0, int(.maxRenderedMessages, 0))
        collapseLongMessages = bool(.collapseLongMessages, false)
        lastUpdateCheck = dbl(.lastUpdateCheck, 0)
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
        // 允许用 MYNA_CONFIG 指向另一份配置：自动化测试可以完全跑在隔离目录里，
        // 不会读写用户真实配置（也便于同时开一个测试实例）。
        path = ProcessInfo.processInfo.environment["MYNA_CONFIG"]
            ?? NSString(string: "~/.config/myna/config.json").expandingTildeInPath
        let fm = FileManager.default
        let rawData = fm.contents(atPath: path)
        if let data = rawData,
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        // 旧配置没有显式声明视觉能力时，按端点推断（DeepSeek 已支持图片输入）。
        let rawHasVisionKey: Bool
        if let rawData,
           let object = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any] {
            rawHasVisionKey = object["supports_vision"] != nil
        } else {
            rawHasVisionKey = false
        }
        // 环境变量覆盖（便于 CLI / CI），不写回配置文件
        suppressSave = true
        applyEnvironmentOverrides()
        suppressSave = false
        // 旧配置迁移：model_profiles / model_list → providers / models（立即落盘）
        suppressSave = true
        let migratedLegacy = migrateLegacyModelData()
        let migratedThinking = migrateThinkingLevels()
        let migratedVision = rawHasVisionKey ? false : migrateDeepSeekVision()
        let migratedHistory = migrateHistoryDefault(rawData: rawData)
        suppressSave = false
        if migratedLegacy || migratedThinking || migratedVision || migratedHistory { writeToDisk() }
    }

    /// 旧默认值 `max_history_turns = 20` 会裁掉最早的用户轮次，导致前缀缓存失效。
    /// 仅当配置里仍是这个旧默认值、且没有显式开启「无限历史」时，迁移为 0（不裁剪）。
    /// 用户自己设过其它数值（例如 16）不会被覆盖。
    private func migrateHistoryDefault(rawData: Data?) -> Bool {
        guard !settings.historyDefaultMigrated else { return false }
        settings.historyDefaultMigrated = true
        // 只对仍然是旧默认 20 的配置生效；用户显式设过其它值则保持不变。
        if settings.maxHistoryTurns == 20, !settings.unlimitedHistoryTurns {
            settings.maxHistoryTurns = 0
        }
        return true
    }

    /// 首次升级到支持视觉的 DeepSeek 配置时，补上 `supports_vision`。
    ///
    /// 只在该键**不存在**时执行；用户显式关闭后不会被再次打开。
    private func migrateDeepSeekVision() -> Bool {
        guard ModelEntry.supportsVisionByDefault(baseURL: settings.baseURL) else { return false }
        var changed = false
        if !settings.supportsVision {
            settings.supportsVision = true
            changed = true
        }
        for pi in settings.providers.indices
        where ModelEntry.supportsVisionByDefault(baseURL: settings.providers[pi].baseURL) {
            for mi in settings.providers[pi].models.indices
            where !settings.providers[pi].models[mi].supportsVision {
                settings.providers[pi].models[mi].supportsVision = true
                changed = true
            }
        }
        return changed
    }

    private func applyEnvironmentOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let v = env["MYNA_BASE_URL"], !v.isEmpty { settings.baseURL = v }
        if let v = env["MYNA_MODEL"], !v.isEmpty { settings.model = v }
        if let v = env["MYNA_HUB_BASE"], !v.isEmpty {
            // 临时来源（CLI / 离线测试用），排在首位以获得最高优先级，不写回配置。
            // reloadFromDisk 会重复调用本方法，先移除旧的 env 来源避免叠加。
            let base = HubSource.expand(v)
            settings.hubSources.removeAll { $0.id == "env" }
            settings.hubSources.insert(HubSource(id: "env", name: "MYNA_HUB_BASE", base: base), at: 0)
        }
        if let v = env["DEEPSEEK_API_KEY"], !v.isEmpty { settings.apiKey = v }
        // 搜索 Key：仅用于 CLI / 自动化验证，不写回配置文件
        if let v = env["MYNA_SEARCH_PROVIDER"], !v.isEmpty { settings.searchProvider = v }
        if let v = env["MYNA_SEARCH_API_KEY"], !v.isEmpty { settings.searchApiKey = v }
        if let v = env["TAVILY_API_KEY"], !v.isEmpty, settings.searchApiKey.isEmpty {
            settings.searchProvider = "tavily"
            settings.searchApiKey = v
        }
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
        // 环境变量注入的临时来源只存在于内存，不写回配置文件。
        var snapshot = settings
        snapshot.hubSources.removeAll { $0.id == "env" }
        guard let data = try? enc.encode(snapshot) else { return }
        FileManager.default.createFile(atPath: path, contents: data)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// 从磁盘重新载入（自我控制工具修改配置文件后调用）。
    ///
    /// 保留环境变量覆盖；不会触发一次回写，避免把只读的环境变量值固化进文件。
    func reloadFromDisk() {
        guard let data = FileManager.default.contents(atPath: path),
              let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return }
        suppressSave = true
        settings = loaded
        applyEnvironmentOverrides()
        suppressSave = false
    }

    func reset() {
        settings = AppSettings()
        // 恢复默认设置后补一个与默认扁平字段一致的供应商，避免列表为空。
        migrateLegacyModelData()
        migrateThinkingLevels()
    }
}
