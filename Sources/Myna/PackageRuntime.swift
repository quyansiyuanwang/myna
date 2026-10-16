import Foundation
import PiKit

/// 线程安全的采样参数快照。
///
/// ``PiAI/ChatProvider`` 的 `stream` 可能在非主线程被调用，而设置由主线程修改，
/// 因此用锁保护，避免数据竞争。参数在每次请求时注入，
/// 这样调整温度 / Top-P 等**不会重建 Agent、不会丢失对话上下文**。
final class SamplingSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var temperature: Double?
    private var topP: Double?
    private var frequencyPenalty: Double?
    private var presencePenalty: Double?
    private var maxTokens: Int?

    func update(_ s: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        temperature = s.temperature
        topP = s.topP
        frequencyPenalty = s.frequencyPenalty
        presencePenalty = s.presencePenalty
        maxTokens = s.maxTokens
    }

    func apply(to options: ChatOptions) -> ChatOptions {
        lock.lock(); defer { lock.unlock() }
        var o = options
        if let temperature { o.temperature = temperature }
        if let topP { o.topP = topP }
        if let frequencyPenalty { o.frequencyPenalty = frequencyPenalty }
        if let presencePenalty { o.presencePenalty = presencePenalty }
        if let maxTokens { o.maxTokens = maxTokens }
        return o
    }
}

/// 把 ``SamplingSnapshot`` 的当前值注入每次请求的 provider 装饰器。
struct LiveSamplingProvider: ChatProvider {
    let base: any ChatProvider
    let snapshot: SamplingSnapshot

    func stream(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        base.stream(model: model, context: context, options: snapshot.apply(to: options))
    }
}

/// 基于组合层 `PiKit`（其内部为 PiAI + PiAgentCore）的运行时装配。
///
/// 运行期完全不依赖 Node.js：`AgentKit` 直接装配 `OpenAICompletionsProvider`
/// 发起的 HTTPS 流式请求，`PiAgentCore.Agent` 负责「助手 ↔ 工具」循环，
/// 本机工具通过 ``ToolRunner/packageTools(disabled:)`` 注入。
enum PackageRuntime {

    /// 依据 App 设置构造组合层配置（模型 / 生成参数 / 系统提示 / 工具）。
    ///
    /// 子代理会通过 `systemPrompt` / `maxToolRounds` / `tools` 覆盖默认值，
    /// 从而拥有独立的提示、轮数与工具集。
    static func makeConfiguration(
        _ settings: AppSettings,
        systemPrompt: String? = nil,
        maxToolRounds: Int? = nil,
        tools: [any AgentTool]? = nil
    ) -> AgentConfiguration {
        AgentConfiguration(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: settings.model,
            api: settings.api,
            contextWindow: 128_000,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topP: settings.topP,
            frequencyPenalty: settings.frequencyPenalty,
            presencePenalty: settings.presencePenalty,
            systemPrompt: systemPrompt ?? LocalResources.systemPrompt(base: settings.systemPrompt),
            maxToolRounds: maxToolRounds ?? settings.effectiveMaxToolRounds,
            tools: tools ?? ToolRunner.packageTools(disabled: settings.disabledTools)
        )
    }

    /// 依据 App 设置构造 PiAI 模型描述。
    static func makeModel(_ settings: AppSettings) -> Model {
        AgentKit.model(makeConfiguration(settings))
    }

    /// 按接口类型选择 provider，并注入该协议对应的推理参数。
    static func makeProvider(_ settings: AppSettings) -> any ChatProvider {
        switch APIType.from(settings.api) {
        case .openAICompletions:
            return OpenAICompletionsProvider(maxRetries: settings.maxRetries)
        case .openAIResponses:
            var p = OpenAIResponsesProvider(maxRetries: settings.maxRetries)
            if !settings.reasoningEffort.isEmpty { p.reasoningEffort = settings.reasoningEffort }
            return p
        case .anthropicMessages:
            var p = AnthropicMessagesProvider(maxRetries: settings.maxRetries)
            if settings.thinkingBudget > 0 { p.reasoningBudgetTokens = settings.thinkingBudget }
            return p
        case .googleGenerativeAI:
            var p = GoogleGenerativeAIProvider(maxRetries: settings.maxRetries)
            if settings.thinkingBudget > 0 { p.thinkingBudget = settings.thinkingBudget }
            return p
        }
    }

    /// 构造一个可直接 `prompt` 的 `Agent`（含工具与系统提示）。
    /// 采样参数通过 ``LiveSamplingProvider`` 在请求时注入，不在 Agent 创建时固定。
    static func makeAgent(
        _ settings: AppSettings,
        sampling: SamplingSnapshot,
        systemPrompt: String? = nil,
        maxToolRounds: Int? = nil,
        tools: [any AgentTool]? = nil
    ) -> Agent {
        let base = makeProvider(settings)
        let provider = LiveSamplingProvider(base: base, snapshot: sampling)
        return AgentKit.makeAgent(
            makeConfiguration(settings,
                              systemPrompt: systemPrompt,
                              maxToolRounds: maxToolRounds,
                              tools: tools),
            provider: provider
        )
    }

    // MARK: - 事件格式化（委托给 PiKit.AgentText）

    /// 从内容块中拼接纯文本。
    static func text(of blocks: [ContentBlock]) -> String {
        AgentText.text(of: blocks)
    }

    /// 返回一段 run 中最后一条 assistant 文本。
    static func finalAnswer(in messages: [Message]) -> String {
        AgentText.finalAnswer(in: messages)
    }

    /// 把工具参数 JSON 渲染成单行（空对象返回空串）。
    static func describe(_ value: JSONValue) -> String {
        AgentText.describe(value)
    }
}
