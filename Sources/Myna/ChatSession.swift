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
    /// 最近一轮运行的完整用量（含缓存命中与请求次数），仅用于界面展示。
    var lastUsage: TokenUsage?
    /// 本轮已发出的模型请求数；用于 `max_requests_per_run` 的实时拦截。
    var requestsThisRun = 0
    /// 本轮累计用量；逐条 assistant 消息累加，运行被中止时也能落账。
    var usageThisRun = TokenUsage()
    /// 连续相同工具调用的签名与次数；用于阻止轮询式死循环。
    var lastToolSignature: String?
    var repeatedToolCount = 0
    /// 包运行时的 transcript 是否需要在发送前从气泡重建（截断 / 清空 / 导入后为 true）。
    var transcriptDirty = false
    /// 当前会话完整的消息历史（用于落盘与重启后恢复前缀）。
    var savedTranscript: [Message] = []
    /// 当前模式与目标；变化会重建 Agent（保留 transcript）。
    var mode: ChatMode = .normal
    var goal: Goal?
    /// 正在压缩上下文时阻止重复触发。
    var compacting = false
    /// 本轮是否因错误/费用限制中止；目标模式据此决定是否续跑。
    var lastRunFailed = false
    /// 会话切换时异步重建 transcript 的任务；发送前必须等它结束，避免与 prompt 竞争。
    var transcriptTask: Task<Void, Never>?

    init(conversationID: UUID, builtinAgent: BuiltinAgent, workingDirectory: String) {
        self.conversationID = conversationID
        self.builtinAgent = builtinAgent
        self.workingDirectory = workingDirectory
        builtinAgent.workingDirectory = workingDirectory
    }
}
