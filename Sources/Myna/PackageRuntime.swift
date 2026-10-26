import Foundation
import CryptoKit
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
        tools: [any AgentTool]? = nil,
        workingDirectory: String? = nil
    ) -> AgentConfiguration {
        let dir = ToolRunner.workingDirectory(workingDirectory)
        return AgentConfiguration(
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
            systemPrompt: systemPrompt ?? LocalResources.systemPrompt(base: settings.systemPrompt,
                                                                        codingMode: settings.codingMode,
                                                                        workingDirectory: dir),
            maxToolRounds: maxToolRounds ?? settings.effectiveMaxToolRounds,
            tools: tools ?? ToolRunner.packageTools(disabled: settings.disabledTools,
                                                    workingDirectory: dir)
        )
    }

    /// 依据 App 设置构造 PiAI 模型描述。
    static func makeModel(_ settings: AppSettings) -> Model {
        var model = AgentKit.model(makeConfiguration(settings))
        if settings.supportsVision {
            model.input = [.text, .image]
        }
        return model
    }

    /// 按接口类型选择 provider，并注入该协议对应的推理参数。
    ///
    /// `settings.reasoningEffort` / `settings.thinkingBudget` 是当前模型的**解析后**值
    /// （见 `SettingsStore.applyActiveSelection()`）：
    /// - effort 协议（openai-completions / openai-responses）直接发送等级；
    /// - budget 协议（anthropic / google）发送解析后的预算。
    static func makeProvider(_ settings: AppSettings) -> any ChatProvider {
        // 「关闭」与空等价：不发送对应字段。
        let effort = settings.reasoningEffort == "off" ? "" : settings.reasoningEffort
        if ProcessInfo.processInfo.environment["MYNA_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[myna] provider api=\(settings.api) 发送 reasoning_effort=\(effort.isEmpty ? "(省略)" : effort) thinking_budget=\(settings.thinkingBudget)\n".utf8))
        }
        // 所有出网请求都走同一套会话配置，使「网络代理」对模型、搜索、更新一并生效。
        let http = NetworkProxy.httpClient(settings)
        let stream = NetworkProxy.streamingClient(settings)
        switch APIType.from(settings.api) {
        case .openAICompletions:
            var p = OpenAICompletionsProvider(httpClient: http, streamingClient: stream,
                                              maxRetries: settings.maxRetries)
            if !effort.isEmpty { p.reasoningEffort = effort }
            return p
        case .openAIResponses:
            var p = OpenAIResponsesProvider(httpClient: http, streamingClient: stream,
                                            maxRetries: settings.maxRetries)
            if !effort.isEmpty { p.reasoningEffort = effort }
            return p
        case .anthropicMessages:
            var p = AnthropicMessagesProvider(httpClient: http, streamingClient: stream,
                                              maxRetries: settings.maxRetries)
            if settings.thinkingBudget > 0 { p.reasoningBudgetTokens = settings.thinkingBudget }
            return p
        case .googleGenerativeAI:
            var p = GoogleGenerativeAIProvider(httpClient: http, streamingClient: stream,
                                               maxRetries: settings.maxRetries)
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
        tools: [any AgentTool]? = nil,
        workingDirectory: String? = nil
    ) -> Agent {
        let base = makeProvider(settings)
        let provider = LiveSamplingProvider(base: base, snapshot: sampling)
        let configuration = makeConfiguration(settings,
                                              systemPrompt: systemPrompt,
                                              maxToolRounds: maxToolRounds,
                                              tools: tools,
                                              workingDirectory: workingDirectory)
        // AgentKit 默认只声明文本输入；视觉模型需要显式把 image 加入模态，
        // 否则 OpenAI Responses / Google 的请求构造会丢弃工具返回的图片。
        var model = AgentKit.model(configuration)
        if settings.supportsVision {
            model.input = [.text, .image]
        }
        let configured = ConfiguredProvider(
            provider,
            temperature: configuration.temperature,
            maxTokens: configuration.maxTokens,
            topP: configuration.topP,
            frequencyPenalty: configuration.frequencyPenalty,
            presencePenalty: configuration.presencePenalty
        )
        let options = AgentOptions(
            systemPrompt: configuration.systemPrompt,
            model: model,
            tools: configuration.tools,
            provider: CacheProbe.wrap(configured),
            apiKey: configuration.apiKey,
            maxToolRounds: configuration.maxToolRounds
        )
        return Agent(options: options)
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

// MARK: - 缓存命中诊断

/// `MYNA_DEBUG_CACHE=1` 时记录每次请求的前缀指纹与用量。
///
/// 用途：判断「命中率低」是服务端/模型不支持，还是 Myna 自己改变了前缀
/// （工具 Schema、系统提示词、历史消息顺序）。日志只写哈希与计数，不写正文。
enum CacheProbe {
    static func wrap(_ provider: any ChatProvider) -> any ChatProvider {
        guard ProcessInfo.processInfo.environment["MYNA_DEBUG_CACHE"] == "1" else { return provider }
        return CacheProbeProvider(base: provider)
    }

    struct Fingerprint {
        let hash: String
        let systemChars: Int
        let toolCount: Int
        let messageHashes: [String]
        let startedAt: Date
    }

    nonisolated(unsafe) private static var lastHashes: [String] = []
    private static let lock = NSLock()

    static func begin(_ context: ChatContext) -> Fingerprint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let system = context.systemPrompt ?? ""
        let tools = context.tools
        let messageData = context.messages.compactMap { try? encoder.encode($0) }
        let messageHashes = messageData.map(hash)
        var combined = Data(system.utf8)
        if let toolsData = try? encoder.encode(tools) { combined.append(toolsData) }
        messageData.forEach { combined.append($0) }
        return Fingerprint(hash: hash(combined),
                           systemChars: system.count,
                           toolCount: tools.count,
                           messageHashes: messageHashes,
                           startedAt: Date())
    }

    static func end(_ fp: Fingerprint, usage: Usage?, error: Error?) {
        lock.lock()
        let previous = lastHashes
        lastHashes = fp.messageHashes
        lock.unlock()

        var shared = 0
        for (lhs, rhs) in zip(previous, fp.messageHashes) where lhs == rhs { shared += 1 }
        let elapsed = Date().timeIntervalSince(fp.startedAt)
        var line = "\(ISO8601DateFormatter().string(from: Date()))"
            + " fp=\(fp.hash) sys=\(fp.systemChars) tools=\(fp.toolCount)"
            + " msgs=\(fp.messageHashes.count) sharedPrefix=\(shared)/\(fp.messageHashes.count)"
        if let usage {
            let prompt = usage.input + usage.cacheRead + usage.cacheWrite
            let rate = prompt > 0 ? Double(usage.cacheRead) / Double(prompt) * 100 : 0
            line += " input=\(usage.input) cacheRead=\(usage.cacheRead)"
                + " output=\(usage.output) hit=\(String(format: "%.0f", rate))%"
        }
        if let error { line += " error=\(String(describing: type(of: error)))" }
        line += String(format: " %.2fs", elapsed)
        append(line)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ line: String) {
        let path = LocalResources.configDir + "/cache.log"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: LocalResources.configDir, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 1_048_576 {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            fm.createFile(atPath: path, contents: data)
        }
    }
}

private struct CacheProbeProvider: ChatProvider {
    let base: any ChatProvider

    func stream(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        let fingerprint = CacheProbe.begin(context)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in base.stream(model: model, context: context, options: options) {
                        switch event {
                        case .done(let message):
                            CacheProbe.end(fingerprint, usage: message.usage, error: nil)
                        case .error(let error):
                            CacheProbe.end(fingerprint, usage: nil, error: error)
                        default:
                            break
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    CacheProbe.end(fingerprint, usage: nil, error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
