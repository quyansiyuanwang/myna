import Foundation
import PiKit

/// 基于组合层 `PiKit`（其内部为 PiAI + PiAgentCore）的运行时装配。
///
/// 运行期完全不依赖 Node.js：`AgentKit` 直接装配 `OpenAICompletionsProvider`
/// 发起的 HTTPS 流式请求，`PiAgentCore.Agent` 负责「助手 ↔ 工具」循环，
/// 本机工具通过 ``ToolRunner/packageTools(disabled:)`` 注入。
enum PackageRuntime {

    /// 依据 App 设置构造组合层配置（模型 / 生成参数 / 系统提示 / 工具）。
    static func makeConfiguration(_ settings: AppSettings) -> AgentConfiguration {
        AgentConfiguration(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: settings.model,
            provider: "deepseek",
            contextWindow: 128_000,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topP: settings.topP,
            frequencyPenalty: settings.frequencyPenalty,
            presencePenalty: settings.presencePenalty,
            systemPrompt: settings.systemPrompt,
            tools: ToolRunner.packageTools(disabled: settings.disabledTools)
        )
    }

    /// 依据 App 设置构造 PiAI 模型描述。
    static func makeModel(_ settings: AppSettings) -> Model {
        AgentKit.model(makeConfiguration(settings))
    }

    /// 构造一个可直接 `prompt` 的 `Agent`（含工具与系统提示）。
    static func makeAgent(_ settings: AppSettings) -> Agent {
        let provider = OpenAICompletionsProvider(maxRetries: settings.maxRetries)
        return AgentKit.makeAgent(makeConfiguration(settings), provider: provider)
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
