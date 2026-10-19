import Foundation
import PiKit

/// 一段对话的运行上下文。
///
/// 每个会话各自持有自己的 Agent、流式状态与任务，因此切换会话（或关闭面板）
/// 不会打断正在进行的运行，多个会话也可以并行。
@MainActor
final class RunContext {
    let conversationID: UUID
    /// 内置兜底运行时（每会话一份，保留各自的消息历史）。
    let builtinAgent: BuiltinAgent
    /// 解析后的会话工作目录（会话自设 > 应用默认 > 用户主目录）。
    var workingDirectory: String

    // MARK: 包运行时（PiAI + PiAgentCore）
    var packageAgent: Agent?
    var packageUnsubscribe: (() -> Void)?
    var packageTask: Task<Void, Never>?
    var builtinTask: Task<Void, Never>?
    /// 包运行时的配置签名（模型 / 系统提示 / 工具等）；变化时重建 Agent。
    var signature = ""

    // MARK: 运行状态
    var streaming = ""
    var streamingStart: Date?
    var thinking = ""
    var busy = false
    var cancelling = false
    /// 本次运行开始时间（并行上限淘汰最旧会话时使用）。
    var startedAt: Date?

    /// 该会话的完整气泡：后台运行也写这里，再回写会话存储。
    var bubbles: [Bubble] = []
    /// 最近一轮运行的 token 用量（输入 / 输出），仅用于界面展示。
    var runTokens: (input: Int, output: Int)?

    init(conversationID: UUID, builtinAgent: BuiltinAgent, workingDirectory: String) {
        self.conversationID = conversationID
        self.builtinAgent = builtinAgent
        self.workingDirectory = workingDirectory
        builtinAgent.workingDirectory = workingDirectory
    }
}
