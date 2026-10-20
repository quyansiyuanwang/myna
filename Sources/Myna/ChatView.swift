import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PiKit

struct Bubble: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String
    let date: Date

    init(role: ChatRole, text: String, date: Date = Date()) {
        self.role = role
        self.text = text
        self.date = date
    }
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var bubbles: [Bubble] = []
    @Published var input = ""
    @Published var busy = false
    @Published var isRecording = false
    /// 流式文本的界面刷新节流（见 ``setStreaming``）。
    ///
    /// 刷新成本主要是 SwiftUI 的**文本布局**，随文本长度上升；
    /// 因此按当前长度自适应：短文本 66ms（约 15 帧/秒），长文本放宽到 150ms。
    static let streamFlushInterval: TimeInterval = 0.066
    /// 流式刷新间隔。
    ///
    /// 关键性质：**每次刷新的成本与文本长度成正比**（整段文本要重新排版），
    /// 所以固定间隔必然在长回答上把 CPU 打满。实测 80 字/秒、3000 字回答时，
    /// 0.066s 的间隔会持续占用约 57% 单核；按长度分档后降到个位数到两成。
    /// 短文本仍然保持高帧率，视觉上没有明显差别。
    func streamFlushInterval(forLength length: Int) -> TimeInterval {
        if length > 12_000 { return 0.60 }
        if length > 5_000 { return 0.40 }
        if length > 2_000 { return 0.25 }
        if length > 800 { return 0.12 }
        return Self.streamFlushInterval
    }
    private var lastStreamFlush = Date.distantPast
    private var pendingStreamFlush: DispatchWorkItem?
    private var lastThinkingFlush = Date.distantPast
    private var pendingThinkingFlush: DispatchWorkItem?
    @Published var streaming = ""
    @Published var streamingStart: Date?
    @Published var thinking = ""
    /// 正在运行的会话 id（前台 + 后台）
    @Published var runningConversations: Set<UUID> = []
    /// 折叠区块的手动展开/收起覆盖（默认值来自设置）
    @Published var blockOverrides: [UUID: Bool] = [:]
    /// 处理过程分组的展开/收起覆盖（key 为分组 id）
    @Published var groupOverrides: [String: Bool] = [:]
    /// 搜索命中后需要滚动到的气泡
    @Published var pendingScrollTarget: UUID?
    /// 搜索命中后短暂高亮的气泡
    @Published var highlightedBubble: UUID?
    @Published var liveTranscript = ""
    /// 窗口是否可见（不可见时不自动接听）
    @Published var windowVisible = false

    let speech = SpeechRecognizer()

    /// 每个会话一份运行上下文；切换会话或关闭面板都不会打断后台运行。
    private var contexts: [UUID: RunContext] = [:]
    /// 手动结束录音时是否直接发送（由快捷键路径设置）
    private var pendingAutoSend = false
    /// 抑制本次 onStateChange 触发的自动发送（避免与显式 send 重复）
    private var suppressAutoSend = false
    /// 采样参数快照（请求时注入，不重建 Agent）
    private let sampling = SamplingSnapshot()
    /// 会话存储
    private let store = ConversationStore.shared

    private var settings: AppSettings { SettingsStore.shared.settings }

    init() {
        // 听写只更新「聆听中」预览，不碰输入框，避免覆盖你已编辑的内容
        speech.onUpdate = { [weak self] t in
            self?.liveTranscript = t
        }
        speech.onStateChange = { [weak self] recording in
            guard let self else { return }
            self.isRecording = recording
            if !recording {
                self.commitTranscript()
                let shouldSend = !self.suppressAutoSend
                    && (SettingsStore.shared.settings.autoSendOnSilence || self.pendingAutoSend)
                self.pendingAutoSend = false
                if shouldSend && !self.busy { self.send() }
            }
        }
        // 一段回答朗读完后，若开启连续对话则自动接着听
        Speaker.shared.onFinish = { [weak self] in
            guard let self else { return }
            guard SettingsStore.shared.settings.continuousMode, self.windowVisible, !self.busy else { return }
            self.startVoice()
        }
        // 初始化会话：有则恢复最近一段，无则新建
        if store.conversations.isEmpty {
            store.create()
        } else if store.currentID == nil {
            store.currentID = store.conversations.first?.id
        }
        load(store.current)
    }

    // MARK: - 会话

    var conversations: [Conversation] { store.conversations }
    var currentConversationID: UUID? { store.currentID }

    /// 当前模型声明的上下文窗口（0 表示未声明）。
    var currentModelContextWindow: Int {
        SettingsStore.shared.currentModelEntry?.contextWindow ?? 0
    }

    // MARK: - 运行上下文

    /// 取得（必要时创建）某个会话的运行上下文，并接好内置运行时的回调。
    func context(for id: UUID) -> RunContext {
        let resolved = resolvedWorkingDirectory(for: id)
        if let ctx = contexts[id] {
            // 会话工作目录可能在会话列表 / 顶栏被修改；保持上下文与其同步。
            if ctx.workingDirectory != resolved {
                ctx.workingDirectory = resolved
                ctx.builtinAgent.workingDirectory = resolved
            }
            return ctx
        }
        let ctx = RunContext(conversationID: id, builtinAgent: BuiltinAgent(), workingDirectory: resolved)
        if let c = store.conversations.first(where: { $0.id == id }) {
            ctx.bubbles = c.bubbles.map { Bubble(role: ChatRole.from($0.role), text: $0.text, date: $0.date) }
        }
        wireBuiltinCallbacks(ctx)
        rebuildHistory(ctx)
        contexts[id] = ctx
        return ctx
    }

    /// 解析某会话的工作目录：会话自设 > 应用默认 > 用户主目录。
    private func resolvedWorkingDirectory(for id: UUID) -> String {
        let own = store.conversations.first(where: { $0.id == id })?.workingDirectory ?? ""
        return ToolRunner.workingDirectory(own)
    }

    /// 设置某会话自己的工作目录（空字符串 = 回到应用默认）。
    /// 目录变化会改变该会话的 Agent 签名，下次运行时自动重建 Agent。
    func setWorkingDirectory(_ path: String, for id: UUID) {
        store.setWorkingDirectory(id, to: path)
        guard let ctx = contexts[id] else { return }
        let resolved = resolvedWorkingDirectory(for: id)
        guard ctx.workingDirectory != resolved else { return }
        ctx.workingDirectory = resolved
        ctx.builtinAgent.workingDirectory = resolved
    }

    /// 自检用：某会话解析后的工作目录。
    func workingDirectory(for id: UUID) -> String { context(for: id).workingDirectory }

    /// 自检用：某会话当前的 Agent 配置签名（未创建 Agent 时为空）。
    func agentSignature(for id: UUID) -> String? { contexts[id]?.signature }

    /// 自检用：某会话当前持有的包运行时 Agent 身份。
    func agentIdentity(for id: UUID) -> ObjectIdentifier? {
        guard let agent = contexts[id]?.packageAgent else { return nil }
        return ObjectIdentifier(agent)
    }

    /// 自检用：按当前设置为某会话构建包运行时 Agent（不发起请求）。
    @discardableResult
    func ensureAgentForCheck(for id: UUID) async -> Bool {
        let ctx = context(for: id)
        _ = await ensurePackageAgent(for: ctx)
        return ctx.packageAgent != nil
    }

    func isCurrent(_ ctx: RunContext) -> Bool { ctx.conversationID == store.currentID }

    /// 内置运行时的流式 / 思考 / 工具回调，全部路由回所属会话。
    private func wireBuiltinCallbacks(_ ctx: RunContext) {
        ctx.builtinAgent.onDelta = { [weak self, weak ctx] chunk in
            DispatchQueue.main.async {
                guard let self, let ctx else { return }
                if ctx.streamingStart == nil { ctx.streamingStart = Date() }
                self.setStreaming(ctx.streaming + chunk, start: ctx.streamingStart, for: ctx)
            }
        }
        ctx.builtinAgent.onThinking = { [weak self, weak ctx] chunk in
            DispatchQueue.main.async {
                guard let self, let ctx else { return }
                self.setThinking(ctx.thinking + chunk, for: ctx)
            }
        }
        ctx.builtinAgent.onTool = { [weak self, weak ctx] name, result in
            DispatchQueue.main.async {
                guard let self, let ctx else { return }
                self.flushThinking(for: ctx)
                if !ctx.streaming.isEmpty {
                    self.appendBubble(Bubble(role: .assistant, text: ctx.streaming, date: ctx.streamingStart ?? Date()), to: ctx)
                    self.setStreaming("", start: nil, for: ctx)
                }
                self.appendBubble(Bubble(role: .toolResult, text: "\(name) → \(result)"), to: ctx)
                if self.isCurrent(ctx),
                   SettingsStore.shared.settings.speakToolResults,
                   SettingsStore.shared.settings.voiceEnabled, !result.isEmpty {
                    Speaker.shared.say(result)
                }
            }
        }
    }

    /// 依据存储的气泡重建内置运行时的消息历史。
    private func rebuildHistory(_ ctx: RunContext) {
        ctx.builtinAgent.settings = settings
        ctx.builtinAgent.workingDirectory = ctx.workingDirectory
        ctx.builtinAgent.reset()
        for b in ctx.bubbles where b.role == .user || b.role == .assistant {
            ctx.builtinAgent.messages.append([
                "role": b.role == .user ? "user" : "assistant",
                "content": b.text,
            ])
        }
    }

    /// 把某个上下文的气泡写回所属会话（标题自动生成、更新时间戳）。
    private func persist(_ ctx: RunContext) {
        guard var c = store.conversations.first(where: { $0.id == ctx.conversationID }) else { return }
        c.bubbles = ctx.bubbles.map { StoredBubble(role: $0.role.rawValue, text: $0.text, date: $0.date) }
        if c.title == "新对话", !c.bubbles.isEmpty {
            c.title = Conversation.derivedTitle(from: c.bubbles)
        }
        c.updatedAt = Date()
        store.update(c)
    }

    private func appendBubble(_ bubble: Bubble, to ctx: RunContext) {
        ctx.bubbles.append(bubble)
        persist(ctx)
        if isCurrent(ctx) { bubbles = ctx.bubbles }
    }

    private func setStreaming(_ value: String, start: Date?, for ctx: RunContext) {
        ctx.streaming = value
        ctx.streamingStart = start
        guard isCurrent(ctx) else { return }
        // 注意：`streamingStart` 也是 @Published，之前在这里**每次 tick 都赋值**，
        // 等于每秒 50 次全量重绘，把下面的文本节流完全绕过了（长对话直接打满单核）。
        // 只在真正推送界面时一起更新。
        // 流式刷新节流：每个 token 都写 `@Published` 会让整棵消息列表重渲染、
        // 重新解析 Markdown、并重新启动滚动动画（长回答下是 O(n²) 的开销）。
        // 这里保证 `ctx.streaming` 始终完整，只把 **界面刷新** 限到约 15 次/秒。
        let now = Date()
        let interval = streamFlushInterval(forLength: value.count)
        let elapsed = now.timeIntervalSince(lastStreamFlush)
        if elapsed >= interval {
            lastStreamFlush = now
            if streamingStart != start { streamingStart = start }
            streaming = value
            pendingStreamFlush?.cancel()
            pendingStreamFlush = nil
        } else if pendingStreamFlush == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStreamFlush = nil
                self.lastStreamFlush = Date()
                guard let id = self.currentConversationID, let c = self.contexts[id] else { return }
                self.streaming = c.streaming
            }
            pendingStreamFlush = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, streamFlushInterval(forLength: value.count) - elapsed),
                                          execute: item)
        }
    }

    /// 自检探针：以固定节奏把固定文本推入当前会话的流式状态。
    ///
    /// 用于确定性量化流式渲染开销（LLM 输出长度每次都不同，无法做可靠对比）。
    func runStreamProbe(characters: Int, chunk: Int = 12, interval: TimeInterval? = nil) {
        // 真实节奏对照：MYNA_DEBUG_STREAM_RATE=每秒字符数（默认按 600 字/秒压测）
        let interval = interval
            ?? ProcessInfo.processInfo.environment["MYNA_DEBUG_STREAM_RATE"]
                .flatMap { Double($0) }.map { max(0.005, Double(chunk) / $0) }
            ?? 0.02
        guard let id = currentConversationID else { return }
        let ctx = context(for: id)
        let unit = "Swift 结构化并发让取消与错误沿作用域自动传导。"
        let text = String(repeating: unit, count: characters / unit.count + 1)
        var index = text.startIndex
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard index < text.endIndex else {
                    timer.invalidate()
                    self.setStreaming("", start: nil, for: ctx)
                    return
                }
                let end = text.index(index, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
                index = end
                self.setStreaming(String(text[text.startIndex..<end]), start: Date(), for: ctx)
            }
        }
    }

    /// 立即把待刷新的流式文本推给界面（工具切换、运行结束等关键时机）。
    private func flushStreaming(for ctx: RunContext) {
        pendingStreamFlush?.cancel()
        pendingStreamFlush = nil
        lastStreamFlush = Date()
        guard isCurrent(ctx) else { return }
        streaming = ctx.streaming
        streamingStart = ctx.streamingStart
    }

    private func setThinking(_ value: String, for ctx: RunContext) {
        ctx.thinking = value
        guard isCurrent(ctx) else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastThinkingFlush)
        if elapsed >= Self.streamFlushInterval {
            lastThinkingFlush = now
            thinking = value
            pendingThinkingFlush?.cancel()
            pendingThinkingFlush = nil
        } else if pendingThinkingFlush == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingThinkingFlush = nil
                self.lastThinkingFlush = Date()
                guard let id = self.currentConversationID, let c = self.contexts[id] else { return }
                self.thinking = c.thinking
            }
            pendingThinkingFlush = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.streamFlushInterval - elapsed),
                                          execute: item)
        }
    }

    /// 立即把待刷新的思考文本推给界面。
    private func flushThinkingNow(for ctx: RunContext) {
        pendingThinkingFlush?.cancel()
        pendingThinkingFlush = nil
        lastThinkingFlush = Date()
        guard isCurrent(ctx) else { return }
        thinking = ctx.thinking
    }

    private func setBusy(_ value: Bool, for ctx: RunContext) {
        ctx.busy = value
        if value {
            runningConversations.insert(ctx.conversationID)
            if ctx.startedAt == nil { ctx.startedAt = Date() }
        } else {
            runningConversations.remove(ctx.conversationID)
            ctx.startedAt = nil
        }
        if isCurrent(ctx) { busy = value }
    }

    /// 把某会话的运行状态镜像到界面（仅在它是当前会话时）。
    private func mirrorAll(_ ctx: RunContext) {
        guard isCurrent(ctx) else { return }
        bubbles = ctx.bubbles
        streaming = ctx.streaming
        streamingStart = ctx.streamingStart
        thinking = ctx.thinking
        busy = ctx.busy
    }

    func newConversation() {
        store.create()
        load(store.current)
    }

    func selectConversation(_ id: UUID, focusBubbleAt index: Int? = nil) {
        if id != store.currentID {
            store.currentID = id
            load(store.conversations.first { $0.id == id })
        }
        guard let index, index >= 0, index < bubbles.count else { return }
        let target = bubbles[index].id
        pendingScrollTarget = target
        highlightedBubble = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.highlightedBubble == target { self?.highlightedBubble = nil }
        }
    }

    func deleteConversation(_ id: UUID) {
        if let ctx = contexts[id] {
            cancelContext(ctx)
            contexts[id] = nil
        }
        let wasCurrent = store.currentID == id
        store.delete(id)
        if store.conversations.isEmpty { store.create() }
        if wasCurrent { load(store.current) }
    }

    func renameCurrent(_ title: String) {
        if let id = store.currentID { store.rename(id, to: title) }
    }

    /// 停止某个会话正在进行的运行（会话列表中也可直接停止）。
    func stopConversation(_ id: UUID) {
        guard let ctx = contexts[id], ctx.busy else { return }
        if isCurrent(ctx) { Speaker.shared.stop() }
        cancelContext(ctx)
    }

    /// 把当前会话序列化为 JSON。
    func exportData() -> Data? {
        guard let c = store.current else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(c)
    }

    /// 从 JSON 导入为一段新会话并切换过去。
    @discardableResult
    func importData(_ data: Data) -> Bool {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let c = try? dec.decode(Conversation.self, from: data) else { return false }
        load(store.insert(c))
        return true
    }

    /// 把一段会话载入界面。`background_runs` 关闭时切换会取消其它运行（旧行为）；
    /// 开启时其它会话继续在后台运行。
    private func load(_ c: Conversation?) {
        if !settings.backgroundRuns {
            for ctx in contexts.values where ctx.busy && ctx.conversationID != c?.id {
                cancelContext(ctx)
            }
        }
        speech.stop()
        guard let c else {
            bubbles = []
            streaming = ""
            streamingStart = nil
            thinking = ""
            busy = false
            liveTranscript = ""
            return
        }
        let ctx = context(for: c.id)
        if !ctx.busy {
            ctx.cancelling = false
            rebuildHistory(ctx)
            if usePackageRuntime {
                let msgs = c.agentMessages(model: settings.model, api: settings.api)
                Task { [weak self, weak ctx] in
                    guard let self, let ctx else { return }
                    let a = await self.ensurePackageAgent(for: ctx)
                    await a.setTranscript(msgs)
                }
            } else if let pa = ctx.packageAgent {
                Task { await pa.reset() }
            }
        }
        mirrorAll(ctx)
        liveTranscript = ""
    }

    /// 录音结束：把听写结果追加到输入框（不覆盖已有/已编辑文本）
    func commitTranscript() {
        let t = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscript = ""
        guard !t.isEmpty else { return }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = t
        } else if input.hasSuffix(" ") || input.hasSuffix("\n") {
            input += t
        } else {
            input += " " + t
        }
    }

    /// 回车：若在录音则先结束并并入文字，再发送
    func submit() {
        send()
    }

    func send() {
        pendingAutoSend = false
        if isRecording {                          // 发送前强制关麦克风
            suppressAutoSend = true
            speech.stop()
            suppressAutoSend = false
        }
        Speaker.shared.stop()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = store.currentID else { return }
        let ctx = context(for: id)
        guard !ctx.busy else { return }
        input = ""
        ctx.cancelling = false
        appendBubble(Bubble(role: .user, text: text), to: ctx)
        // 并行上限：先淘汰最旧的运行，再启动本次
        startRun(text, for: ctx)
    }

    /// 追加用户气泡后启动一次运行（发送 / 重发 / 编辑重发共用的收尾逻辑）。
    private func startRun(_ text: String, for ctx: RunContext) {
        enforceParallelLimit(excluding: ctx.conversationID)
        setStreaming("", start: nil, for: ctx)
        setThinking("", for: ctx)
        setBusy(true, for: ctx)
        sampling.update(settings)
        Speaker.shared.configure(settings)
        if usePackageRuntime { sendViaPackage(text, for: ctx) } else { sendViaBuiltin(text, for: ctx) }
    }

    /// 并行运行数超过 `max_parallel_runs` 时，取消最旧的会话并留一条提示。
    private func enforceParallelLimit(excluding id: UUID) {
        let limit = max(1, settings.maxParallelRuns)
        let running = contexts.values
            .filter { $0.busy && $0.conversationID != id }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        guard running.count >= limit else { return }
        let excess = running.count - limit + 1
        for ctx in running.prefix(excess) {
            cancelContext(ctx)
            appendBubble(Bubble(role: .error,
                                text: "后台并行上限（\(limit)）已到，本次运行已自动停止。"),
                         to: ctx)
        }
    }

    /// 用建议芯片填入输入框（不直接发送，允许用户修改）
    func useSuggestion(_ text: String) {
        input = text
    }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - 消息操作：重发 / 编辑重发

    /// 找到包含指定气泡的会话上下文及其下标（当前会话优先，其次后台上下文）。
    private func contextAndIndex(for bubbleID: UUID) -> (RunContext, Int)? {
        var ordered: [RunContext] = []
        if let id = store.currentID {
            ordered.append(context(for: id))
        }
        for ctx in contexts.values where !ordered.contains(where: { $0.conversationID == ctx.conversationID }) {
            ordered.append(ctx)
        }
        for ctx in ordered {
            if let idx = ctx.bubbles.firstIndex(where: { $0.id == bubbleID }) {
                return (ctx, idx)
            }
        }
        return nil
    }

    /// 重发一条消息：用户消息按原文本重发；助手消息从其前一条用户消息处重新生成。
    func resend(bubbleID: UUID) {
        guard let (ctx, idx) = contextAndIndex(for: bubbleID), !ctx.busy else { return }
        switch ctx.bubbles[idx].role {
        case .user:
            truncateAndResend(from: idx, text: ctx.bubbles[idx].text, in: ctx)
        case .assistant, .error:
            guard let userIdx = ctx.bubbles[..<idx].lastIndex(where: { $0.role == .user }) else { return }
            truncateAndResend(from: userIdx, text: ctx.bubbles[userIdx].text, in: ctx)
        default:
            return
        }
    }

    /// 编辑一条用户消息并重发（非用户消息忽略）。
    func editAndResend(bubbleID: UUID, text: String) {
        guard let (ctx, idx) = contextAndIndex(for: bubbleID), !ctx.busy else { return }
        guard ctx.bubbles[idx].role == .user else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        truncateAndResend(from: idx, text: trimmed, in: ctx)
    }

    /// 截断会话到 `index` 之前，重建 Agent transcript 与历史，再发送 `text`。
    ///
    /// 这里操作的是会话自己的 ``RunContext``（而非界面镜像 `bubbles`），
    /// 因此后台会话同样可用。
    private func truncateAndResend(from index: Int, text: String, in ctx: RunContext) {
        guard index >= 0, index < ctx.bubbles.count, !ctx.busy else { return }
        ctx.bubbles.removeSubrange(index...)
        ctx.cancelling = false
        setStreaming("", start: nil, for: ctx)
        setThinking("", for: ctx)
        // 内置运行时：直接用截断后的气泡重建消息历史。
        rebuildHistory(ctx)
        persist(ctx)
        if isCurrent(ctx) { mirrorAll(ctx) }
        if usePackageRuntime {
            // 包运行时：先同步标记运行中（避免异步重建 transcript 期间被误判为空闲），
            // 再重建 transcript，最后发送。
            let msgs = transcriptMessages(for: ctx)
            setBusy(true, for: ctx)
            Task { [weak self, weak ctx] in
                guard let self, let ctx else { return }
                let agent = await self.ensurePackageAgent(for: ctx)
                await agent.setTranscript(msgs)
                self.appendBubble(Bubble(role: .user, text: text), to: ctx)
                self.startRun(text, for: ctx)
            }
        } else {
            appendBubble(Bubble(role: .user, text: text), to: ctx)
            startRun(text, for: ctx)
        }
    }

    /// 由某个上下文的气泡重建包运行时的消息列表。
    private func transcriptMessages(for ctx: RunContext) -> [Message] {
        let stored = ctx.bubbles.map { StoredBubble(role: $0.role.rawValue, text: $0.text, date: $0.date) }
        return Conversation.agentMessages(from: stored, model: settings.model, api: settings.api)
    }

    /// 自检用：把某会话的真实 Agent transcript 拼成纯文本。
    func transcriptText(for id: UUID) async -> String {
        guard let ctx = contexts[id] else { return "" }
        if let agent = ctx.packageAgent {
            return (await agent.transcript).compactMap { messageText($0) }.joined(separator: "\n")
        }
        return ctx.builtinAgent.messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
    }

    /// 自检用：transcript 的条目数。
    func transcriptLineCount(for id: UUID) async -> Int {
        guard let ctx = contexts[id] else { return 0 }
        if let agent = ctx.packageAgent {
            return (await agent.transcript).count
        }
        return ctx.builtinAgent.messages.count
    }

    /// 从 PiKit 的 `Message` 中提取可读文本（自检用）。
    private func messageText(_ m: Message) -> String? {
        switch m {
        case .user(let u): return u.content.textValue
        case .assistant(let a):
            return a.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: " ")
        default:
            return nil
        }
    }

    /// 运行时选择：`auto` / `package` 走 Swift 包；`builtin` 走内置实现。
    /// 内置实现只支持 openai-completions，其他协议强制走包运行时。
    private var usePackageRuntime: Bool {
        if APIType.from(settings.api) != .openAICompletions { return true }
        return settings.agentRuntime != "builtin"
    }

    /// 取消当前会话的回答/工具调用；其它后台会话不受影响。
    func cancel() {
        guard let id = store.currentID else { return }
        let ctx = context(for: id)
        guard ctx.busy else { return }
        Speaker.shared.stop()
        cancelContext(ctx)
    }

    /// 中止某个上下文的运行并清空它的流式状态。
    private func cancelContext(_ ctx: RunContext) {
        ctx.cancelling = true
        ctx.builtinTask?.cancel()
        ctx.packageTask?.cancel()
        if let a = ctx.packageAgent { Task { await a.abort() } }
        setStreaming("", start: nil, for: ctx)
        setThinking("", for: ctx)
        setBusy(false, for: ctx)
    }

    /// 把累积的思考内容落成一条可折叠区块。
    private func flushThinking(for ctx: RunContext) {
        let t = ctx.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingThinkingFlush?.cancel()
        pendingThinkingFlush = nil
        lastThinkingFlush = Date()
        setThinking("", for: ctx)
        guard !t.isEmpty else { return }
        appendBubble(Bubble(role: .thinking, text: t), to: ctx)
    }

    private func finishRun(answer: String, for ctx: RunContext) {
        guard !ctx.cancelling else { return }
        flushThinking(for: ctx)
        flushStreaming(for: ctx)
        let finalText = ctx.streaming.isEmpty ? answer : ctx.streaming
        if !ctx.streaming.isEmpty {
            appendBubble(Bubble(role: .assistant, text: ctx.streaming, date: ctx.streamingStart ?? Date()), to: ctx)
            setStreaming("", start: nil, for: ctx)
        } else if !answer.isEmpty {
            appendBubble(Bubble(role: .assistant, text: answer), to: ctx)
        }
        if isCurrent(ctx), settings.voiceEnabled, !finalText.isEmpty { Speaker.shared.say(finalText) }
        setBusy(false, for: ctx)
        if isCurrent(ctx), settings.continuousMode, !settings.voiceEnabled { startVoice() }
        notifyIfBackground(ctx, answer: finalText)
    }

    /// 统计本次运行的 token 消费并累加到会话（`agentEnd` 只带本轮产生的消息）。
    private func recordTokenUsage(_ messages: [Message], for ctx: RunContext) {
        var input = 0, output = 0
        for message in messages {
            guard case .assistant(let assistant) = message else { continue }
            input += assistant.usage.input
            output += assistant.usage.output
        }
        guard input > 0 || output > 0 else { return }
        ConversationStore.shared.addTokenUsage(ctx.conversationID, input: input, output: output)
        if isCurrent(ctx) {
            ctx.runTokens = (input, output)
        }
    }

    /// 后台会话（非当前会话）跑完时发系统通知。
    private func notifyIfBackground(_ ctx: RunContext, answer: String) {
        guard settings.backgroundNotifications else { return }
        guard ctx.conversationID != currentConversationID else { return }
        let title = ConversationStore.shared.conversations
            .first { $0.id == ctx.conversationID }?.title ?? "对话"
        NotificationBridge.shared.postBackgroundCompletion(
            conversationID: ctx.conversationID,
            title: title,
            body: answer
        )
    }

    // MARK: - Swift 包运行时（PiAI + PiAgentCore）

    /// 设置（模型 / 系统提示 / 工具开关等）变化时重建 Agent；否则复用同一实例以保留上下文。
    private func ensurePackageAgent(for ctx: RunContext) async -> Agent {
        let sig = packageSignatureValue(for: ctx)
        if let agent = ctx.packageAgent, ctx.signature == sig { return agent }
        ctx.packageUnsubscribe?()
        let previous = ctx.packageAgent
        let agent = PackageRuntime.makeAgent(settings, sampling: sampling,
                                             workingDirectory: ctx.workingDirectory)
        ctx.packageUnsubscribe = agent.subscribe { [weak self, weak ctx] event in
            Task { @MainActor in
                guard let self, let ctx else { return }
                self.handlePackageEvent(event, for: ctx)
            }
        }
        ctx.packageAgent = agent
        ctx.signature = sig
        // 重建时沿用旧 transcript，避免切换模型 / 思考强度丢失上下文。
        if let previous {
            let msgs = await previous.transcript
            if !msgs.isEmpty { await agent.setTranscript(msgs) }
        }
        return agent
    }

    /// 该会话的 Agent 配置签名；包含解析后的会话工作目录，
    /// 因此修改目录只重建该会话的 Agent，不影响其他会话。
    private func packageSignatureValue(for ctx: RunContext) -> String {
        let s = settings
        return [s.model, s.baseURL, s.systemPrompt, s.apiKey, s.api,
                s.reasoningEffort, String(s.thinkingBudget),
                String(s.maxRetries), String(s.maxToolRounds),
                String(s.unlimitedToolRounds),
                String(s.codingMode), ctx.workingDirectory,
                s.disabledTools.sorted().joined(separator: ",")].joined(separator: "\u{1F}")
    }

    private func handlePackageEvent(_ event: AgentEvent, for ctx: RunContext) {
        guard !ctx.cancelling else { return }
        switch event {
        case .messageUpdate(_, let update):
            if case .thinkingDelta(let delta) = update {
                setThinking(ctx.thinking + delta, for: ctx)
            }
            if case .textDelta(let delta) = update {
                if ctx.streamingStart == nil { ctx.streamingStart = Date() }
                setStreaming(ctx.streaming + delta, start: ctx.streamingStart, for: ctx)
            }

        case .toolExecutionStart(_, let name, let arguments):
            flushThinking(for: ctx)
            flushStreaming(for: ctx)
            if !ctx.streaming.isEmpty {
                appendBubble(Bubble(role: .assistant, text: ctx.streaming, date: ctx.streamingStart ?? Date()), to: ctx)
                setStreaming("", start: nil, for: ctx)
            }
            let args = PackageRuntime.describe(arguments)
            appendBubble(Bubble(role: .tool, text: args.isEmpty ? name : "\(name) \(args)"), to: ctx)

        case .toolExecutionEnd(_, let name, let result, let isError):
            let text = PackageRuntime.text(of: result.content)
            appendBubble(Bubble(role: isError ? .error : .toolResult, text: "\(name) → \(text)"), to: ctx)
            flushStreaming(for: ctx)
            if isCurrent(ctx), settings.speakToolResults, settings.voiceEnabled, !text.isEmpty {
                Speaker.shared.say(text)
            }

        case .agentEnd(let messages):
            recordTokenUsage(messages, for: ctx)
            finishRun(answer: PackageRuntime.finalAnswer(in: messages), for: ctx)

        default:
            break
        }
    }

    private func sendViaPackage(_ text: String, for ctx: RunContext) {
        ctx.packageTask = Task { [weak self, weak ctx] in
            guard let self, let ctx else { return }
            let agent = await self.ensurePackageAgent(for: ctx)
            do {
                try await agent.prompt(text)
            } catch {
                guard !ctx.cancelling else { return }
                if error is CancellationError || Task.isCancelled { return }
                self.setStreaming("", start: nil, for: ctx)
                self.appendBubble(Bubble(role: .error, text: error.localizedDescription), to: ctx)
                self.setBusy(false, for: ctx)
            }
        }
    }

    // MARK: - 内置兜底运行时

    private func sendViaBuiltin(_ text: String, for ctx: RunContext) {
        ctx.builtinAgent.settings = settings
        ctx.builtinAgent.workingDirectory = ctx.workingDirectory
        ctx.builtinTask = Task { [weak self, weak ctx] in
            guard let self, let ctx else { return }
            do {
                let answer = try await ctx.builtinAgent.ask(text)
                if !ctx.cancelling { self.finishRun(answer: answer, for: ctx) }
            } catch {
                guard !ctx.cancelling else { return }
                if error is CancellationError || Task.isCancelled { return }
                self.setStreaming("", start: nil, for: ctx)
                self.appendBubble(Bubble(role: .error, text: error.localizedDescription), to: ctx)
                self.setBusy(false, for: ctx)
            }
        }
    }

    func toggleMic() {
        if isRecording { stopVoice(send: false) } else { startVoice() }
    }

    /// 结束录音；`send` 为 true 时结束后立即发送。
    func stopVoice(send: Bool) {
        guard isRecording else { return }
        pendingAutoSend = send
        speech.stop()
    }

    func startVoice() {
        guard !isRecording else { return }
        Speaker.shared.stop()        // 打断正在朗读的回答
        liveTranscript = ""
        speech.applySettings(settings)
        speech.requestPermission { [weak self] ok in
            guard let self else { return }
            if ok {
                self.speech.start()
            } else if let id = self.store.currentID {
                let ctx = self.context(for: id)
                self.appendBubble(Bubble(role: .error, text: "需要「麦克风」和「语音识别」权限，请在 系统设置 → 隐私与安全性 中授权 Myna。"), to: ctx)
            }
        }
    }

    func clear() {
        guard let id = store.currentID else { return }
        let ctx = context(for: id)
        if ctx.busy {
            Speaker.shared.stop()
            cancelContext(ctx)
        }
        speech.stop()
        ctx.bubbles.removeAll()
        ctx.cancelling = false
        setStreaming("", start: nil, for: ctx)
        setThinking("", for: ctx)
        rebuildHistory(ctx)
        if let pa = ctx.packageAgent { Task { await pa.reset() } }
        persist(ctx)
        mirrorAll(ctx)
        liveTranscript = ""
    }
}

// MARK: - 聊天界面

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var convos = ConversationStore.shared
    /// 新版本提示角标（见「设置 → 关于 → 更新」）。
    @ObservedObject private var updateCenter = UpdateCenter.shared
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}
    var onResize: (CGSize) -> Void = { _ in }
    /// 拖拽结束时调用一次，用于把最终尺寸落盘
    var onResizeEnd: () -> Void = {}
    /// 查询宿主真实内容尺寸（由 AppDelegate 提供，避免依赖 keyWindow）
    var onQuerySize: () -> CGSize = { .zero }

    /// 模型 / 思考强度弹窗的开关状态（由 AppDelegate 托管真正的弹窗）
    @ObservedObject private var modelPopup = ModelPopupState.shared
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool
    @State private var liveThinkingExpanded: Bool?
    @State private var showConversations = false
    @State private var showFilter = false
    @State private var filterQuery = ""
    @State private var showPrompts = false
    @State private var showPalette = false
    /// 是否已滚动到最底部（决定是否显示「跳到最新」按钮）
    /// 列表缓存（可见消息 / 导航轨轮次 / 分组行）。
    ///
    /// 用引用类型盛放：在布局期间刷新它不会触发 SwiftUI 的更新周期。
    /// 这三份数据都只依赖「消息 + 相关设置」，流式期间不应每帧重算——
    /// 500 条消息时每帧复制一次数组会让 ARC 成为最大开销。
    @State private var listCache = ListCache()
    /// 缓存的上下文 token 估算
    @State private var cachedTokens = 0
    @State private var atBottom = true
    /// 鼠标是否停在某个刻度上
    @State private var hoveredTickIndex: Int?
    /// 最后展示预览的轮次（鼠标移入卡片后仍保留）
    @State private var previewTurnIndex: Int?
    /// 预览卡片自身是否被悬停（用于允许在卡片内滚动）
    @State private var hoveringPreview = false
    @State private var previewHideWork: DispatchWorkItem?
    /// 预览卡片实测高度（用于竖向居中）
    @State private var previewHeight: CGFloat = 0
    /// 预览卡片对应的刻度在轨道可视区内的中心 Y（含轨道滚动偏移）
    @State private var previewTickY: CGFloat = 0
    /// 预览正文的实测高度（ScrollView 是贪婪的，必须按内容给高度，否则短 prompt 也会撑满）
    @State private var previewTextHeight: CGFloat = 0
    /// 点击某个刻度后固定高亮，直到用户再次手动滚动
    @State private var pinnedTurnIndex: Int?
    /// 程序化滚动的时间窗（窗内不算「用户手动滚动」）
    @State private var programmaticScrollUntil = Date.distantPast
    @State private var didInitialScroll = false
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// 底部锚点在文档坐标系里的真实位置（比内容高度可靠）
    @State private var contentBottomY: CGFloat = 0
    /// 用 AppKit 观察滚动位置（SwiftUI 偏好值在滚动时不更新）
    private var scrollObserver: some View {
        ZStack {
            ScrollObserver { offset, bottomY, viewport in
                // 用户手动滚动时解除点击固定的高亮（程序化滚动的时间窗内不算）
                if pinnedTurnIndex != nil, Date() > programmaticScrollUntil,
                   abs(offset - scrollOffset) > 1 {
                    pinnedTurnIndex = nil
                }
                scrollOffset = offset
                if bottomY > 0 { contentBottomY = bottomY }
                viewportHeight = viewport
                updateAtBottom()
            }
            // 内容末尾的锚点观测器：给出真实的内容底部
            ScrollObserver(role: .bottomAnchor) { _, bottomY, _ in
                _ = 0
                if bottomY > 0, abs(bottomY - contentBottomY) > 0.5 { contentBottomY = bottomY }
            }
        }
        .frame(width: 0, height: 0)
    }
    /// 调试/自动化：预填命令面板的查询（MYNA_DEBUG_PALETTE_QUERY）。
    private var paletteInitialQuery: String {
        ProcessInfo.processInfo.environment["MYNA_DEBUG_PALETTE_QUERY"] ?? ""
    }
    @State private var dragBase: CGSize?
    /// 流式滚动节流（见 ``scrollToEndThrottled``）：`scrollTo` 会触发整棵布局，
    /// 逐分片滚动实测占主线程约 37%。
    private static let scrollInterval: TimeInterval = 0.25
    /// 消息列表底部的稳定锚点 id。
    private static let bottomAnchorID = "myna-bottom"
    /// 滚动坐标系名称（用于观测位置）
    private static let scrollSpace = "myna-scroll"
    @State private var lastScrollAt = Date.distantPast
    @State private var pendingScroll: DispatchWorkItem?
    @State private var prompts: [PromptTemplate] = []
    @State private var hoverModel = false
    @State private var hoverResize = false
    @State private var hoveredSuggestion: String?
    @State private var chipAreaWidth: CGFloat = 0
    /// 当前悬停的消息气泡（决定操作条是否显现）
    @State private var hoveredBubble: UUID?
    /// 刚复制过的气泡（图标短暂变成勾）
    @State private var copiedBubble: UUID?
    /// 正在内联编辑的用户气泡
    @State private var editingBubble: UUID?
    @State private var editText = ""

    private var theme: ChatTheme { ChatTheme(store.settings) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissModelControl() })
            Divider()
            if showFilter { filterBar }
            messages
                .simultaneousGesture(TapGesture().onEnded { dismissModelControl() })
            Divider()
            inputBar
            if store.settings.resizablePanel {
                resizeStrip
            }
            // ⌘K 命令面板：隐藏按钮承载快捷键（面板模式下菜单快捷键不一定能到达）
            Button("") { showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(theme.accent)
        .overlay {
            if showPalette {
                ZStack {
                    // 半透明遮罩：点击即关闭
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { showPalette = false }
                    VStack {
                        CommandPalette(theme: theme, items: paletteItems,
                                       messageSearch: { searchMessages($0) },
                                       initialQuery: paletteInitialQuery,
                                       onClose: { showPalette = false })
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 40)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            focused = true
            prompts = LocalResources.prompts()
            // 调试/自动化：直接展开模型与思考强度面板（MYNA_DEBUG_MODEL_PANEL=1）
            if let raw = ProcessInfo.processInfo.environment["MYNA_DEBUG_TURN_PREVIEW"],
               let index = Int(raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showTurnPreview(index) }
            }
            if ProcessInfo.processInfo.environment["MYNA_DEBUG_PALETTE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showPalette = true }
            }
            if ProcessInfo.processInfo.environment["MYNA_DEBUG_MODEL_PANEL"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ModelPopupState.shared.isOpen = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mynaShowCommandPalette)) { _ in
            showPalette = true
        }
        .onExitCommand {
            if editingBubble != nil {
                cancelEdit()
            } else if modelPopup.isOpen {
                ModelPopupState.shared.isOpen = false
            } else {
                onClose()
            }
        }
    }

    /// 右下角尺寸手柄所在的细条：独立于输入栏，避免覆盖或抢走发送按钮的点击。
    private var resizeStrip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            resizeHandle
        }
        .frame(height: 8)
        // 负边距把命中区推到面板可视边缘，箭头才真正落在右下角
        .padding(.trailing, -8)
        .padding(.bottom, -3)
    }

    /// 面板右下角拖拽调整尺寸的手柄；平时低调，悬停时显现。
    /// 取宿主真实内容尺寸作为拖拽基准（由 AppDelegate 上报，避免依赖 keyWindow）。
    private func currentContentSize() -> CGSize {
        let reported = onQuerySize()
        if reported.width > 0, reported.height > 0 { return reported }
        return CGSize(width: store.settings.windowWidth, height: store.settings.windowHeight)
    }

    private var resizeHandle: some View {
        ResizeGrip(
            onDrag: { delta in
                // 以拖拽起点时的真实尺寸为基准，整个拖拽过程只取一次。
                let base = dragBase ?? currentContentSize()
                if dragBase == nil { dragBase = base }
                // 面板模式下面板相对状态栏图标**横向居中**：宽度 +Δ 时右边缘只移动 Δ/2，
                // 手柄会落后光标一半。这里对横向位移乘 2，让右边缘与光标 1:1
                // （纵向是顶部锚定，本身 1:1，无需补偿）。
                //
                // 用固定倍数而非常量量测：NSPopover 的重定位在下一轮布局才发生，
                // 逐帧量测会形成正反馈（曾导致尺寸剧烈跳动）。
                let factor: CGFloat = store.settings.panelMode ? 2 : 1
                onResize(CGSize(width: base.width + delta.width * factor,
                                height: base.height + delta.height))
            },
            onEnd: {
                dragBase = nil
                onResizeEnd()
            }
        )
        .frame(width: 44, height: 12)
        .help("拖拽调整面板大小")
    }

    // MARK: 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: store.settings.menuBarIcon)
                .font(.system(size: 15))
                .foregroundColor(theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Myna").font(.system(size: 13, weight: .semibold))
                    workingDirectoryChip
                }
                HStack(spacing: 4) {
                    if model.isRecording || model.busy || backgroundRunningCount > 0 {
                        Text(statusText).font(theme.tinyFont).foregroundColor(.secondary).lineLimit(1)
                    } else {
                        Text(runtimeLabel).font(theme.tinyFont).foregroundColor(.secondary).lineLimit(1)
                        Text("· \(contextUsageText)").font(theme.tinyFont)
                            .foregroundColor(contextUsageWarning ? .orange : .secondary)
                            .lineLimit(1)
                            .help(contextHelp)
                    }
                }
            }
            .help(runtimeHelp)
            Spacer()

            compactToggle(icon: "speaker.wave.2.fill", on: store.settings.voiceEnabled,
                          help: "朗读回答") { store.settings.voiceEnabled.toggle() }
            compactToggle(icon: "infinity", on: store.settings.continuousMode,
                          help: "连续对话：朗读完自动接着听") { store.settings.continuousMode.toggle() }

            // 语音开关与操作按钮之间用分隔线归组。
            Divider().frame(height: 16)

            Button { showPalette = true } label: { headerIcon("magnifyingglass", active: showPalette) }
                .buttonStyle(.plain).modifier(HoverHighlight()).help("命令面板（⌘K）：搜索会话、执行动作、插入提示词")
            Button { showFilter.toggle() } label: { headerIcon("line.3.horizontal.decrease.circle", active: showFilter) }
                .buttonStyle(.plain).modifier(HoverHighlight()).help("筛选消息")
            conversationMenu
            Button { model.newConversation() } label: { headerIcon("plus") }
                .buttonStyle(.plain).modifier(HoverHighlight()).help("新建对话")
            Button { onOpenSettings() } label: {
                headerIcon("gearshape")
                    .overlay(alignment: .topTrailing) {
                        // 发现新版本时在齿轮上点一个小角标，保持克制不打扰。
                        if updateCenter.badgeVisible {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 6, height: 6)
                                .offset(x: -1, y: 1)
                        }
                    }
            }
            .buttonStyle(.plain).modifier(HoverHighlight()).help("设置")
        }
        .padding(.horizontal, theme.density.contentPadding)
        .padding(.vertical, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundColor(.secondary)
            TextField("筛选消息…", text: $filterQuery)
                .textFieldStyle(.roundedBorder)
                .font(theme.smallFont)
            if !filterQuery.isEmpty {
                Button { filterQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("清除筛选")
            }
        }
        .padding(.horizontal, theme.density.contentPadding)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        if model.isRecording { return "正在聆听…（再按一次快捷键结束）" }
        if model.busy { return "思考中…" }
        if backgroundRunningCount > 0 { return "\(backgroundRunningCount) 个会话在后台运行" }
        return "\(store.settings.model) · \(runtimeLabel)"
    }

    /// 当前会话生效的工作目录（自设优先，否则应用默认，再否则 `~`）。
    private var effectiveWorkingDirectory: String {
        ToolRunner.workingDirectory(convos.current?.workingDirectory)
    }

    /// 当前会话是否自设了工作目录。
    private var hasCustomWorkingDirectory: Bool {
        let raw = convos.current?.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !raw.isEmpty
    }

    /// 顶栏 Myna 标题右侧的工作目录胶囊：**始终可见**，点击弹出选择菜单。
    /// 自设时用强调色，使用默认值时保持低调。
    private var workingDirectoryChip: some View {
        let path = effectiveWorkingDirectory
        let custom = hasCustomWorkingDirectory
        let name = (path as NSString).lastPathComponent
        return Button { showWorkingDirectoryMenu() } label: {
            HStack(spacing: 3) {
                Image(systemName: custom ? "folder.fill" : "folder")
                    .font(.system(size: 9))
                Text(name.isEmpty ? path : name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(custom ? theme.accent : .secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: 96, minHeight: 17)
            .background(Capsule().fill(custom ? theme.accent.opacity(0.14)
                                             : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(custom ? "会话工作目录：\(path)（点击更换）"
                     : "默认工作目录：\(path)（点击为当前会话指定）")
    }

    /// 弹出工作目录菜单。
    ///
    /// 用 AppKit `NSMenu` 而不是 SwiftUI `Menu`：后者嵌在聊天面板的 `NSPopover` 中时
    /// 会被 transient 行为抢先关闭，点击项不生效。
    private func showWorkingDirectoryMenu() {
        let path = effectiveWorkingDirectory
        let custom = hasCustomWorkingDirectory
        WorkingDirectoryMenu.show(
            current: path,
            isCustom: custom,
            onChoose: { pickWorkingDirectory() },
            onUseDefault: {
                if let id = convos.currentID { model.setWorkingDirectory("", for: id) }
            },
            onReveal: {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
        )
    }

    /// 为当前会话挑选工作目录（与会话列表共用同一个选择器）。
    private func pickWorkingDirectory() {
        guard let id = convos.currentID else { return }
        let current = convos.current?.workingDirectory ?? ""
        guard let path = WorkingDirectoryPicker.choose(message: "选择当前会话的工作目录",
                                                      current: current) else { return }
        model.setWorkingDirectory(path, for: id)
    }

    /// 除当前会话外，正在后台运行的会话数量。
    private var backgroundRunningCount: Int {
        model.runningConversations.filter { $0 != model.currentConversationID }.count
    }

    /// 估算当前对话的 token 占用（粗略：ASCII 约 4 字符/token，CJK 约 1.5 字符/token）。
    ///
    /// 结果缓存在 `cachedTokens`：这个值每帧都会被顶栏读取，
    /// 逐字符遍历整段对话会让长对话在流式期间白烧 CPU。
    private var estimatedTokens: Int { cachedTokens }

    private func recomputeTokens() {
        var ascii = 0, cjk = 0
        for b in model.bubbles {
            for scalar in b.text.unicodeScalars {
                if scalar.value < 0x2E80 { ascii += 1 } else { cjk += 1 }
            }
        }
        cachedTokens = Int(Double(ascii) / 4.0 + Double(cjk) / 1.5)
    }

    /// 上下文上限（沿用模型的上下文窗口，未知时按 128k）。
    private var contextWindow: Int {
        let window = model.currentModelContextWindow
        return window > 0 ? window : 128_000
    }

    /// 顶栏用量提示：上下文估算 + 本对话累计消费。
    private var contextHelp: String {
        let used = estimatedTokens
        let c = convos.current
        var text = "当前上下文约 \(used) tokens（上限 \(contextWindow)）；40% 以上建议新建对话"
        if let c, c.inputTokens + c.outputTokens > 0 {
            text += "\n本对话累计：输入 \(c.inputTokens) · 输出 \(c.outputTokens)"
        }
        return text
    }

    private var contextUsageText: String {
        let used = estimatedTokens
        return "\(Self.shortTokens(used))/\(Self.shortTokens(contextWindow))"
    }

    /// 占用超过 70% 时用橙色提示。
    private var contextUsageWarning: Bool {
        Double(estimatedTokens) / Double(max(contextWindow, 1)) >= 0.7
    }

    private static func shortTokens(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)" }
        let k = Double(value) / 1_000
        // 整千不显示小数：128k 而不是 128.0k
        return k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
    }

    private var runtimeLabel: String {
        switch store.settings.agentRuntime {
        case "builtin": return "内置运行时"
        case "package": return "Swift 运行时"
        default: return "自动"
        }
    }

    /// 运行时状态的完整说明，鼠标悬停时展示。
    private var runtimeHelp: String {
        switch store.settings.agentRuntime {
        case "builtin": return "当前运行时：内置实现（仅支持 openai-completions 协议）"
        case "package": return "当前运行时：Swift 包（PiKit）"
        default: return "当前运行时：自动选择（非 openai-completions 协议时使用 Swift 包）"
        }
    }

    /// 顶部栏图标按钮：统一 12pt 图标与 24×22 命中区。
    private func headerIcon(_ systemName: String, active: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12))
            .foregroundColor(active ? theme.accent : Color.secondary)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
    }

    private func compactToggle(icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(on ? theme.accent : Color.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .help(help)
    }

    // MARK: 消息列表

    /// 按显示设置与搜索词过滤后的消息（切换开关会立即影响已有消息）。
    /// 是否已展开超出渲染上限的历史消息。
    @State private var showAllMessages = false

    /// 「显示更早的消息」行。
    @ViewBuilder
    private func loadEarlierRow(_ count: Int) -> some View {
        Button {
            showAllMessages = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle").font(.system(size: 11))
                Text("显示更早的 \(count) 条消息").font(theme.tinyFont)
            }
            .foregroundColor(theme.accent)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help("只影响显示：消息本身没有被删除")
    }

    /// 是否显示思考内容。
    ///
    /// 需要同时满足：设置里打开了「显示思考过程」，且当前模型的思考强度不是「关闭」。
    /// 注意：把等级设为「关闭」只是不再发送 `reasoning_effort`——DeepSeek 等推理模型
    /// 自身仍会产生 reasoning，所以这里再按等级抑制显示，避免“关了还看得见”。
    private var thinkingVisible: Bool {
        guard store.settings.showThinking else { return false }
        return store.settings.reasoningEffort != "off"
    }

    /// 把可见气泡按设置合并成行。
    ///
    /// 用「消息数量 + 末条 id + 相关设置」做签名缓存：流式期间每帧都会重绘，
    /// 如果每次都全量过滤 + 分组，长对话会成为明显的 CPU 开销。
    private var rows: [ChatRow] {
        refreshListCache()
        return listCache.rows
    }

    /// 缓存签名：只依赖消息集合与相关设置。
    private var listCacheKey: String {
        "\(model.bubbles.count)-\(model.bubbles.last?.id.uuidString ?? "")"
            + "-\(store.settings.mergeThinkingBlocks)-\(store.settings.mergeToolBlocks)"
            + "-\(thinkingVisible)-\(filterQuery)"
            + "-\(store.settings.maxRenderedMessages)-\(showAllMessages)"
            + "-\(store.settings.showToolCalls)-\(store.settings.showToolResults)"
            + "-\(store.settings.showErrors)"
    }

    /// 命中缓存直接返回；否则一次性重建可见消息、导航轨轮次与分组行。
    private func refreshListCache() {
        let key = listCacheKey
        guard key != listCache.key else { return }
        let all = computeVisibleBubbles()
        listCache.key = key
        listCache.visible = all
        listCache.userTurns = all.filter { $0.role == .user }
        listCache.rows = buildRows(from: all)
    }

    private func buildRows(from all: [Bubble]) -> [ChatRow] {
        let cap = store.settings.maxRenderedMessages
        var bubbles = all
        var hidden = 0
        if cap > 0 && !showAllMessages && all.count > cap {
            bubbles = Array(all.suffix(cap))
            hidden = all.count - cap
        }
        var out: [ChatRow] = []
        if hidden > 0 { out.append(.loadEarlier(hidden)) }
        var buffer: [Bubble] = []
        var bufferKind: ProcessGroup.Kind?

        func flush() {
            guard let kind = bufferKind, !buffer.isEmpty else { buffer = []; bufferKind = nil; return }
            if buffer.count == 1 {
                out.append(.bubble(buffer[0]))
            } else {
                let id = "g-\(kind == .thinking ? "t" : "x")-\(buffer[0].id.uuidString)"
                out.append(.group(ProcessGroup(id: id, kind: kind, bubbles: buffer)))
            }
            buffer = []
            bufferKind = nil
        }

        for b in bubbles {
            let kind: ProcessGroup.Kind?
            switch b.role {
            case .thinking: kind = store.settings.mergeThinkingBlocks ? .thinking : nil
            case .tool, .toolResult: kind = store.settings.mergeToolBlocks ? .tools : nil
            default: kind = nil
            }
            if let kind, kind == bufferKind {
                buffer.append(b)
                continue
            }
            flush()
            if let kind {
                bufferKind = kind
                buffer = [b]
            } else {
                out.append(.bubble(b))
            }
        }
        flush()
        return out
    }

    private var visibleBubbles: [Bubble] {
        refreshListCache()
        return listCache.visible
    }

    /// 按设置与搜索词过滤后的可见消息。
    private func computeVisibleBubbles() -> [Bubble] {
        let q = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return model.bubbles.filter { b in
            switch b.role {
            case .thinking: if !thinkingVisible { return false }
            case .tool: if !store.settings.showToolCalls { return false }
            case .toolResult: if !store.settings.showToolResults { return false }
            case .error: if !store.settings.showErrors { return false }
            default: break
            }
            if !q.isEmpty, !b.text.lowercased().contains(q) { return false }
            return true
        }
    }

    private var messages: some View {
        Group {
            if isEmptyConversation {
                // 空会话时把欢迎块在可用区域内垂直居中，避免底部留下大片空白。
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                messageScroll
            }
        }
    }

    /// 无可显示内容、且不在思考/回答中。
    private var isEmptyConversation: Bool {
        visibleBubbles.isEmpty && model.streaming.isEmpty && !model.busy
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
            // 导航轨作为左侧列，完全位于 ScrollView 之外：
            // 放在 ScrollView 的 overlay 里时，点击会被底层 NSScrollView 吞掉。
            if userTurns.count >= 2 {
                turnRail(proxy)
                    .padding(.leading, 4)
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.density.rowSpacing) {
                    ForEach(rows) { row in
                        switch row {
                        case .bubble(let b):
                            messageRow(b, streaming: false)
                        case .group(let g):
                            EquatableRow(key: g.id + "|\(g.bubbles.count)"
                                         + "|\(model.groupOverrides[g.id].map { $0 ? 1 : 0 } ?? -1)"
                                         + "|\(colorScheme == .dark)|\(theme.accent.description)") {
                                groupRow(g)
                            }
                        case .loadEarlier(let n):
                            loadEarlierRow(n)
                        }
                    }
                    if !model.thinking.isEmpty && thinkingVisible {
                        liveThinkingBlock
                            .id("thinking")
                    }
                    if !model.streaming.isEmpty {
                        messageRow(Bubble(role: .assistant, text: model.streaming, date: model.streamingStart ?? Date()), streaming: true)
                            .id("streaming")
                    }
                    if model.busy && model.streaming.isEmpty && model.thinking.isEmpty {
                        thinkingRow
                    }
                    // 稳定底部锚点：比滚到「最后一个气泡」可靠得多——
                    // 新气泡（尤其是带标题/表格的 Markdown）高度大，一个 runloop 内
                    // 布局可能还没完成，滚到旧位置就会停在半路。
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)

                }
                .padding(.horizontal, theme.density.contentPadding)
                .padding(.vertical, theme.density.contentPadding)
                .background(scrollObserver)
            }

            .overlay(alignment: .bottomTrailing) {
                // 未贴底时显示「跳到最新」，省去手动往下滑
                if !atBottom {
                    Button {
                        scrollToBottom(proxy, animated: true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 12))
                            Text("最新").font(theme.tinyFont)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Capsule().stroke(theme.bubbleStroke, lineWidth: 1))
                        .modifier(OptionalShadow(theme: theme, radius: 6, y: 2, opacity: 0.22))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
                    .help("跳到最后一条消息")
                    .transition(.opacity)
                }
            }
            .animation(store.settings.reduceVisualEffects ? nil : .easeInOut(duration: 0.15), value: atBottom)
            .onAppear {
                ReduceEffects.isOn = store.settings.reduceVisualEffects
                recomputeTokens()
                // 打开即停在最新消息处（等首帧布局完成）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    scrollToBottomAfterLayout(proxy)
                }
            }
            .onChange(of: model.currentConversationID) { _ in
                // 切换会话后同样贴底
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    scrollToBottomAfterLayout(proxy)
                }
            }
            .coordinateSpace(name: Self.scrollSpace)

            .onChange(of: model.pendingScrollTarget) { target in
                guard let target else { return }
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    model.pendingScrollTarget = nil
                }
            }
            .onChange(of: model.bubbles.count) { _ in
                recomputeTokens()
                // 运行中交给节流滚动，避免与动画互相打断（否则会上下反复滚动）
                if model.busy { scrollToEndThrottled(proxy) } else { scrollToBottomAfterLayout(proxy) }
            }
            .onChange(of: model.streaming) { _ in scrollToEndThrottled(proxy) }
            .onChange(of: model.thinking) { _ in scrollToEndThrottled(proxy) }
            .onChange(of: model.busy) { _ in if !model.busy { scrollToBottomAfterLayout(proxy) } }
            }
            .overlay(alignment: .topLeading) { turnPreviewCard(userTurns) }
        }
    }

    /// 统一滚到列表底部锚点。
    ///
    /// 之前并存两套机制：流式时「瞬时滚到流式气泡」，新气泡时「动画滚到末尾并延迟补滚」。
    /// 流式期间（尤其伴随工具调用时）两者交替触发，表现就是视图上下反复滚动、很不流畅。
    /// 现在只有一个目标（底部锚点）：运行中一律瞬时 + 节流，内容稳定后再动画滚一次。
    /// 根据底部锚点与视口的位置关系更新「是否贴底」。
    private func updateAtBottom() {
        guard viewportHeight > 0, contentBottomY > 0 else { return }
        // 视口底边是否已到达内容底部（容差 4pt，吸收舍入误差）
        let visibleBottom = scrollOffset + viewportHeight
        let next = visibleBottom >= contentBottomY - 4
        if next != atBottom { atBottom = next }
        if ProcessInfo.processInfo.environment["MYNA_DEBUG"] == "1" {
            let line = "atBottom=\(next) offset=\(Int(scrollOffset)) visible=\(Int(visibleBottom)) bottom=\(Int(contentBottomY)) viewport=\(Int(viewportHeight))\n"
            if let d = line.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/myna-debug.log") {
                fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard store.settings.autoScroll else { return }
        DispatchQueue.main.async {
            if animated && !store.settings.reduceVisualEffects {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// 内容稳定后（新气泡追加 / 运行结束）滚到底，并在布局稳定后补一次。
    private func scrollToBottomAfterLayout(_ proxy: ScrollViewProxy) {
        guard store.settings.autoScroll else { return }
        pendingScroll?.cancel()
        pendingScroll = nil
        scrollToBottom(proxy, animated: true)
        // Markdown 气泡（标题、表格、代码块）高度大，首次滚动时布局可能未完成，补一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard store.settings.autoScroll, !model.busy else { return }
            scrollToBottom(proxy, animated: false)
        }
    }

    /// 流式追加时的滚动节流（只做瞬时滚动，避免与动画互相打断）。
    ///
    /// `ScrollViewProxy.scrollTo` 会触发整棵视图树重新布局；逐分片滚动时
    /// 实测占主线程约 37%（采样：1985/5290），是流式期间最大的 CPU 开销。
    /// 这里把它限到约 4 次/秒，内容仍在增长、视觉上依旧跟手。
    private func scrollToEndThrottled(_ proxy: ScrollViewProxy) {
        guard store.settings.autoScroll else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastScrollAt)
        if elapsed >= Self.scrollInterval {
            lastScrollAt = now
            pendingScroll?.cancel()
            pendingScroll = nil
            scrollToBottom(proxy, animated: false)
            return
        }
        guard pendingScroll == nil else { return }
        let item = DispatchWorkItem {
            lastScrollAt = Date()
            pendingScroll = nil
            scrollToBottom(proxy, animated: false)
        }
        pendingScroll = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.scrollInterval - elapsed), execute: item)
    }

    /// 是否还没配置任何可用的模型凭据（首次使用最常见的第一道坎）。
    private var needsSetup: Bool {
        let flat = store.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let anyProvider = store.settings.providers.contains {
            !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return flat.isEmpty && !anyProvider
    }

    /// 首次使用引导：直接给出配置入口，而不是等用户发消息后看到一句报错。
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal").foregroundColor(.orange)
                Text("还没有配置模型").font(.system(size: 13, weight: .semibold))
            }
            Text("填入 API Key 后即可开始。支持 OpenAI 兼容、OpenAI Responses、Anthropic 与 Gemini 四种接口。")
                .font(theme.smallFont).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("打开设置") { onOpenSettings() }
                    .controlSize(.small)
                Text("设置 → 模型 → 供应商与模型").font(theme.tinyFont).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            if needsSetup { setupCard }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundColor(theme.accent)
                    Text("你好，我是 Myna").font(.system(size: 15, weight: .semibold))
                }
                Text("直接说话或打字即可。我由大模型驱动，也能操作这台 Mac。")
                    .font(theme.smallFont).foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                Text("试试这些").font(theme.tinyFont).foregroundColor(.secondary)
                Text("·").font(theme.tinyFont).foregroundColor(.secondary)
                Text("⌘K 搜索会话与动作").font(theme.tinyFont).foregroundColor(.secondary)
            }
            LazyVGrid(columns: chipColumns, spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    suggestionChip(s)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, theme.density.contentPadding)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { chipAreaWidth = geo.size.width }
                .onChange(of: geo.size.width) { w in chipAreaWidth = w }
        })
    }

    /// 建议芯片列数：常规宽度为等宽两列，极窄时退化为单列。
    private var chipColumns: [GridItem] {
        if chipAreaWidth > 0 && chipAreaWidth < 300 {
            return [GridItem(.flexible(), spacing: 8)]
        }
        return [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    /// 单张建议芯片：统一高度、悬停时底色变亮、描边变强调色。
    private func suggestionChip(_ s: String) -> some View {
        let hovering = hoveredSuggestion == s
        return Button { model.useSuggestion(s); focused = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10))
                    .foregroundColor(hovering ? theme.accent : Color.secondary)
                Text(s).font(theme.smallFont).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(hovering ? theme.accent.opacity(0.45) : theme.bubbleStroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredSuggestion = s
            } else if hoveredSuggestion == s {
                hoveredSuggestion = nil
            }
        }
    }

    private let suggestions = [
        "打开计算器，把音量调到 30",
        "播放周杰伦的歌",
        "明天 9 点提醒我开会",
        "查一下电池状态",
        "截个屏并读一下剪贴板",
    ]

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("思考中…").font(theme.smallFont).foregroundColor(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func messageRow(_ b: Bubble, streaming: Bool) -> some View {
        // 整行做值相等短路：流式期间每次刷新都会重建所有可见行的视图值，
        // 没有这一层时 SwiftUI 会重新求值每一行的 body（文本排版就白算了一遍）。
        // 键包含影响渲染的一切：气泡内容、角色、流式状态与主题标识。
        let expandKey = "\(model.blockOverrides[b.id].map { $0 ? 1 : 0 } ?? -1)"
        EquatableRow(key: "\(b.id)|\(b.text.count)|\(b.role.rawValue)|\(streaming)|\(expandKey)|"
                     + "\(colorScheme == .dark)|\(theme.accent.description)|\(theme.fontSize)"
                     + "|\(store.settings.showAvatars)|\(store.settings.showTimestamps)") {
            if b.role.isCollapsible {
                blockRow(b)
            } else {
                bubbleRow(b, streaming: streaming)
            }
        }
    }

    /// 可折叠区块：思考 / 工具调用。
    private func blockRow(_ b: Bubble) -> some View {
        let def = b.role == .thinking ? !store.settings.collapseThinking : !store.settings.collapseTools
        let binding = Binding<Bool>(
            get: { model.blockOverrides[b.id] ?? def },
            set: { model.blockOverrides[b.id] = $0 }
        )
        return DisclosureGroup(isExpanded: binding) {
            MessageBody(text: b.text, markdown: theme.markdown, size: theme.fontSize - 2,
                        theme: theme, isDark: colorScheme == .dark)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .textSelection(.enabled)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: b.role.icon).font(.system(size: 10))
                Text(b.role.name).font(theme.tinyFont.weight(.semibold))
                Text(b.text.replacingOccurrences(of: "\n", with: " "))
                    .font(theme.tinyFont).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            // macOS 的 DisclosureGroup 只有三角箭头能点，标题区域是死的。
            // 补一个点击区域，整行都能展开/收起。
            .contentShape(Rectangle())
            .onTapGesture { binding.wrappedValue.toggle() }
        }
        .padding(.horizontal, theme.density.bubblePaddingH)
        .padding(.vertical, 5)
        .background(b.role == .thinking ? Color.purple.opacity(0.07) : theme.toolBubble)
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .stroke(b.id == model.highlightedBubble ? theme.accent : theme.bubbleStroke,
                    lineWidth: b.id == model.highlightedBubble ? 2 : 1))
        .cornerRadius(theme.cornerRadius)
        .contextMenu { Button("拷贝") { model.copy(b.text) } }
        .id(b.id)
    }

    /// 正在流式输出的思考。
    private var liveThinkingBlock: some View {
        let binding = Binding<Bool>(
            get: { liveThinkingExpanded ?? !store.settings.collapseThinking },
            set: { liveThinkingExpanded = $0 }
        )
        return DisclosureGroup(isExpanded: binding) {
            Text(model.thinking)
                .font(theme.smallFont).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .textSelection(.enabled)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain").font(.system(size: 10))
                Text("思考中…").font(theme.tinyFont.weight(.semibold))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, theme.density.bubblePaddingH)
        .padding(.vertical, 5)
        .background(Color.purple.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.bubbleStroke))
        .cornerRadius(theme.cornerRadius)
    }

    private func bubbleRow(_ b: Bubble, streaming: Bool) -> some View {
        let isUser = b.role == .user
        let editing = editingBubble == b.id
        let showActions = !streaming && !editing && hoveredBubble == b.id
        return HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 32) }

            if !isUser && theme.showAvatars { avatar(b.role) }

            // 用户气泡：操作条排在气泡外侧（左侧）
            if isUser && !streaming {
                bubbleActionColumn(b, visible: showActions)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                if theme.showAvatars || theme.showTimestamps {
                    HStack(spacing: 6) {
                        if theme.showAvatars {
                            Text(b.role.name).font(theme.nameFont).foregroundColor(.secondary)
                        }
                        if theme.showTimestamps {
                            Text(b.date, style: .time).font(theme.tinyFont).foregroundColor(.secondary)
                        }
                    }
                }

                if editing {
                    InlineMessageEditor(
                        text: $editText,
                        theme: theme,
                        canSave: !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.busy,
                        onSave: { saveEdit(b) },
                        onCancel: { cancelEdit() }
                    )
                } else {
                    bubbleContent(b, streaming: streaming)
                }
            }

            // 助手气泡：操作条排在气泡外侧（右侧）
            if !isUser && !streaming {
                bubbleActionColumn(b, visible: showActions)
            }

            if !isUser && theme.showAvatars { Spacer(minLength: 0) }
            if isUser { avatar(b.role) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredBubble = b.id
            } else if hoveredBubble == b.id {
                hoveredBubble = nil
            }
        }
        .id(b.id)
    }

    /// 气泡外侧的悬停操作条：预留固定宽度，避免出现/消失时布局跳动。
    private func bubbleActionColumn(_ b: Bubble, visible: Bool) -> some View {
        let isUser = b.role == .user
        return MessageActionBar(
            busy: model.busy,
            theme: theme,
            copied: copiedBubble == b.id,
            onCopy: { copyBubble(b) },
            onResend: { model.resend(bubbleID: b.id) },
            onEdit: isUser ? { beginEdit(b) } : nil,
            onBranch: { branchHere(b) }
        )
        .padding(.top, 2)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .frame(width: isUser ? 62 : 42, alignment: isUser ? .trailing : .leading)
    }

    private func bubbleContent(_ b: Bubble, streaming: Bool) -> some View {
        let isUser = b.role == .user
        let plainWhileStreaming = streaming && store.settings.streamPlainText
        return MessageBody(text: b.text, markdown: theme.markdown && !isUser && !plainWhileStreaming,
                           size: theme.fontSize, theme: theme,
                           isDark: colorScheme == .dark)
            .equatable()
            .foregroundColor(isUser ? .white : (b.role == .error ? .red : .primary))
            .padding(.horizontal, theme.density.bubblePaddingH)
            .padding(.vertical, theme.density.bubblePaddingV)
            .background(bubbleBackground(b.role))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(b.id == model.highlightedBubble ? theme.accent : theme.bubbleStroke,
                            lineWidth: b.id == model.highlightedBubble ? 2 : 1)
            )
            .cornerRadius(theme.cornerRadius)
            .textSelection(.enabled)
            .contextMenu {
                Button("复制") { copyBubble(b) }
                Button("重发") { model.resend(bubbleID: b.id) }
                Button("从这里分叉…") { branchHere(b) }
                    .disabled(model.busy)
                if isUser {
                    Button("编辑并重发") { beginEdit(b) }
                        .disabled(model.busy)
                    Button("重新填入输入框") { model.useSuggestion(b.text); focused = true }
                }
            }
    }

    /// 复制完整消息并让操作条短暂显示勾选反馈。
    private func copyBubble(_ b: Bubble) {
        model.copy(b.text)
        copiedBubble = b.id
        let id = b.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedBubble == id { copiedBubble = nil }
        }
    }

    /// 进入内联编辑（仅用户消息）。
    private func beginEdit(_ b: Bubble) {
        guard b.role == .user, !model.busy else { return }
        editText = b.text
        editingBubble = b.id
    }

    private func cancelEdit() {
        editingBubble = nil
        editText = ""
    }

    private func saveEdit(_ b: Bubble) {
        let text = editText
        editingBubble = nil
        editText = ""
        model.editAndResend(bubbleID: b.id, text: text)
    }

    private func bubbleBackground(_ role: ChatRole) -> Color {
        switch role {
        case .user: return theme.userBubble
        case .tool: return theme.toolBubble
        case .toolResult: return theme.toolBubble
        case .thinking: return Color.purple.opacity(0.07)
        case .error: return Color.red.opacity(0.10)
        case .assistant: return theme.assistantBubble
        }
    }

    private func avatar(_ role: ChatRole) -> some View {
        ZStack {
            Circle()
                .fill(role == .user ? theme.accent.opacity(0.18) : theme.accent.opacity(0.12))
                .frame(width: 26, height: 26)
            Image(systemName: role.icon)
                .font(.system(size: 11))
                .foregroundColor(role == .user ? theme.accent : theme.accent)
        }
    }

    // MARK: 输入栏

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            iconButton(systemName: model.isRecording ? "mic.fill" : "mic",
                       color: model.isRecording ? .red : .secondary,
                       help: "点击说话；再次点击结束（不发送）。全局快捷键可随时开关录音") {
                model.toggleMic()
            }

            promptsMenu

            inputField()

            modelControlButton

            if model.busy {
                iconButton(systemName: "stop.circle.fill", size: 20, color: .red,
                           help: "打断当前回答") {
                    model.cancel()
                }
            } else {
                sendButton
            }
        }
        .padding(.horizontal, theme.density.contentPadding)
        .padding(.vertical, 8)
    }

    /// 输入栏右侧的模型按钮：显示当前模型名，点开切换模型并拖动调整思考强度。
    ///
    /// 与发送按钮同高、同圆角，镜像排在发送动作左侧，构成一对对称控件。
    /// 点击后展开的是输入栏上方的内联面板（不是嵌套 `NSPopover`）。
    private var modelControlButton: some View {
        let active = modelPopup.isOpen
        return Button {
            ModelPopupState.shared.isOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(store.currentModelLabel.isEmpty ? "选择模型" : store.currentModelLabel)
                    .font(theme.tinyFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(active ? 180 : 0))
            }
            .foregroundColor(active ? theme.accent : Color.secondary)
            .padding(.horizontal, 6)
            .frame(height: 34)
            .frame(maxWidth: 108)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? theme.accent.opacity(0.12)
                             : (hoverModel ? Color.primary.opacity(0.09) : Color.primary.opacity(0.06))))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(active ? theme.accent.opacity(0.35) : theme.bubbleStroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("切换模型与思考强度")
        .onHover { hoverModel = $0 }
    }

    /// 发送按钮：与模型按钮同高、同圆角；可发送时填强调色。
    private var sendButton: some View {
        Button { submit() } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(canSend ? .white : Color.secondary.opacity(0.6))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(canSend ? theme.accent : Color.secondary.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help(sendHint)
    }

    /// 统一尺寸的图标按钮（行高与输入框一致，保证底部对齐）。
    private func iconButton(systemName: String,
                            size: CGFloat = 15,
                            color: Color,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundColor(color)
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight(cornerRadius: 8))
        .help(help)
    }

    private var promptsMenu: some View {
        Button { showPrompts.toggle() } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight(cornerRadius: 8))
        .help("插入提示词模板")
        .popover(isPresented: $showPrompts, arrowEdge: .bottom) {
            PromptListView(
                prompts: prompts,
                onRescan: { prompts = LocalResources.prompts() },
                onOpenDir: { NSWorkspace.shared.open(URL(fileURLWithPath: LocalResources.promptsDir)) },
                onPick: { body in
                    model.useSuggestion(body)
                    showPrompts = false
                    focused = true
                }
            )
        }
    }

    /// 输入框。`sendOnEnter` 开启时回车发送；关闭时不挂 onSubmit，回车换行、⌘回车发送。
    /// 录音时实时转写叠在框内（不额外占行，也不显示多余图标/占位文字）。
    @ViewBuilder
    private func inputField() -> some View {
        let base = TextField(model.isRecording ? "" : "输入或说话…",
                             text: $model.input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(theme.bodyFont)
            .lineLimit(1...6)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.bubbleStroke))
            .cornerRadius(10)
            .overlay(alignment: .topLeading) {
                if model.isRecording, !model.liveTranscript.isEmpty {
                    Text(model.liveTranscript)
                        .font(theme.smallFont)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .focused($focused)
        if store.settings.sendOnEnter {
            base.onSubmit { submit() }
        } else {
            base
        }
    }

    /// 发送前收起内联模型面板，避免它一直挡在输入栏上方。
    private func submit() {
        ModelPopupState.shared.isOpen = false
        model.submit()
    }

    /// 点击面板以外的区域（标题栏 / 消息列表）时收起内联模型面板。
    private func dismissModelControl() {
        guard modelPopup.isOpen else { return }
        ModelPopupState.shared.isOpen = false
    }

    private var canSend: Bool {
        !model.busy && editingBubble == nil
            && (!model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isRecording)
    }

    private var sendHint: String {
        store.settings.sendOnEnter ? "回车发送（⇧回车换行）" : "⌘回车发送（回车换行）"
    }

    // MARK: - 会话菜单

    private var conversationMenu: some View {
        Button { showConversations.toggle() } label: {
            headerIcon("list.bullet", active: showConversations)
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .help("会话")
        .popover(isPresented: $showConversations, arrowEdge: .bottom) {
            ConversationListView(model: model, isPresented: $showConversations)
        }
    }
}

// MARK: - 悬停高亮

/// 统一的图标按钮悬停底色：鼠标进入时叠加一层很弱的 primary 色调，
/// 让顶部栏与输入栏的图标在悬停时有一致的反馈。
private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
            .onHover { hovering = $0 }
    }
}

// MARK: - 消息操作条 / 内联编辑

/// 悬停在气泡上时显现的紧凑操作条（复制 / 重发 / 编辑）。
private struct MessageActionBar: View {
    let busy: Bool
    let theme: ChatTheme
    let copied: Bool
    var onCopy: () -> Void
    var onResend: () -> Void
    var onEdit: (() -> Void)?
    var onBranch: (() -> Void)?

    var body: some View {
        HStack(spacing: 1) {
            actionButton(icon: copied ? "checkmark" : "doc.on.doc",
                         help: copied ? "已复制" : "复制",
                         tint: copied ? theme.accent : Color.secondary,
                         disabled: false,
                         action: onCopy)
            actionButton(icon: "arrow.clockwise",
                         help: busy ? "当前正在运行" : "重发",
                         tint: .secondary,
                         disabled: busy,
                         action: onResend)
            if let onEdit {
                actionButton(icon: "pencil",
                             help: busy ? "当前正在运行" : "编辑并重发",
                             tint: .secondary,
                             disabled: busy,
                             action: onEdit)
            }
            if let onBranch {
                actionButton(icon: "arrow.triangle.branch",
                             help: busy ? "当前正在运行" : "从这里分叉出新对话",
                             tint: .secondary,
                             disabled: busy,
                             action: onBranch)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.bubbleStroke, lineWidth: 1))
    }

    private func actionButton(icon: String, help: String, tint: Color,
                              disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(disabled ? Color.secondary.opacity(0.4) : tint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

/// 用户消息的内联编辑器：⌘↩ 保存并重发，Esc 取消。
private struct InlineMessageEditor: View {
    @Binding var text: String
    let theme: ChatTheme
    let canSave: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $text)
                .font(theme.bodyFont)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minWidth: 220, minHeight: 64, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.accent.opacity(0.5), lineWidth: 1))
                .cornerRadius(theme.cornerRadius)
                .focused($focused)
                .onExitCommand { onCancel() }
            HStack(spacing: 8) {
                Text("⌘↩ 保存并重发 · Esc 取消")
                    .font(theme.tinyFont).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button("取消") { onCancel() }
                    .font(theme.smallFont)
                    .keyboardShortcut(.cancelAction)
                Button("保存并重发") { onSave() }
                    .font(theme.smallFont)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
        }
        .frame(maxWidth: 520, alignment: .trailing)
        .onAppear { focused = true }
    }
}

// MARK: - 消息正文（支持 Markdown 与代码块）

/// 消息正文渲染；设置界面的更新说明也复用同一渲染器。
struct MessageBody: View, Equatable {
    let text: String
    let markdown: Bool
    let size: CGFloat
    var theme: ChatTheme

    /// 值相等即跳过重绘：流式期间每帧都会让整棵列表重新求值，
    /// 已完成的气泡内容没变时不应重绘（`ViewRendererHost.render` 是主要开销）。
    static func == (lhs: MessageBody, rhs: MessageBody) -> Bool {
        lhs.text == rhs.text && lhs.markdown == rhs.markdown
            && lhs.size == rhs.size && lhs.theme == rhs.theme && lhs.isDark == rhs.isDark
    }

    /// 明暗外观：作为**存储属性**传入（而非读 environment），
    /// 这样 `.equatable()` 的比较能覆盖它，切换外观时仍会重绘。
    let isDark: Bool

    private var font: Font { .system(size: size) }
    private var blocks: [MarkdownBlock] { MarkdownParseCache.blocks(for: text) }

    var body: some View {
        if markdown {
            let blocks = self.blocks
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    blockView(block)
                        .padding(.top, MarkdownLayout.gap(index == 0 ? nil : blocks[index - 1], block))
                }
            }
        } else {
            Text(text).font(font)
        }
    }

    // MARK: - 块级渲染

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .code(let code, let language):
            CodeBlockView(code: code, language: language, size: size, theme: theme)

        case .heading(let level, let s):
            VStack(alignment: .leading, spacing: 3) {
                inline(s,
                       textSize: MarkdownLayout.headingSize(level, base: size),
                       weight: MarkdownLayout.headingWeight(level))
                if level <= 2 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 1)
                }
            }

        case .bullet(let depth, let s):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(MarkdownLayout.bulletMark(depth: depth))
                    .font(font)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 9, alignment: .leading)
                inline(s)
            }
            .padding(.leading, MarkdownLayout.listIndent(depth: depth))

        case .ordered(let depth, let number, let s):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(number).")
                    .font(font)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(minWidth: 15, alignment: .trailing)
                inline(s)
            }
            .padding(.leading, MarkdownLayout.listIndent(depth: depth))

        case .blockquote(let s):
            inline(s, baseColor: Color(nsColor: .secondaryLabelColor))
                .padding(.vertical, 1)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.accent.opacity(0.55))
                        .frame(width: 3)
                }

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)

        case .table(let table):
            tableBlock(table)

        case .paragraph(let s):
            inline(s)
        }
    }

    /// 表格：等宽字体 + 按列补齐空格，表头加粗并带下细分隔线。
    private func tableBlock(_ table: MarkdownTable) -> some View {
        let padded = table.paddedLines()
        let mono = Font.system(size: max(10, size - 1), design: .monospaced)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(padded.header)
                    .font(mono.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
                    .padding(.vertical, 3)
                ForEach(Array(padded.rows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(mono)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 内联渲染

    /// 行内 Markdown：先解析成「文本 + 语义样式」，再写入**显式**属性。
    ///
    /// 不依赖 `Text` 解释 `inlinePresentationIntent`（它对 `code` / `strikethrough`
    /// 不生效）。**不能**在 `Text` 上再加 `.font(...)`：同层修饰符会覆盖 run 级
    /// `font` 属性，粗体 / 斜体 / 等宽都会失效。`.base` 前景默认留空以继承外层颜色。
    private func inline(_ s: String,
                        textSize: CGFloat? = nil,
                        weight: Font.Weight = .regular,
                        baseColor: Color? = nil) -> some View {
        let resolved = textSize ?? size
        let attributed = MarkdownInline.attributed(s,
                                                  size: resolved,
                                                  weight: weight,
                                                  accent: theme.accent,
                                                  dark: isDark,
                                                  baseColor: baseColor)
        return Text(attributed).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 代码块

/// 带语言标签与复制按钮的高亮代码块。
///
/// 复制按钮始终复制**原始代码**（不含语言标签）；空代码与超长行也不会撑破布局。
private struct CodeBlockView: View {
    let code: String
    let language: String?
    let size: CGFloat
    let theme: ChatTheme

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var languageName: String { SyntaxLanguage.detect(language).displayName }
    private var codeFont: Font { .system(size: max(11, size - 1), design: .monospaced) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            Text(SyntaxHighlighter.highlight(code, language: language, dark: colorScheme == .dark))
                .font(codeFont)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .stroke(theme.bubbleStroke, lineWidth: 1))
        .cornerRadius(theme.cornerRadius)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(languageName)
                .font(.system(size: max(10, size - 2), weight: .medium))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button {
                copyCode()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "已复制" : "复制")
                }
                .font(.system(size: max(9, size - 3)))
                .foregroundColor(copied ? theme.accent : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制代码")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
    }

    private func copyCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }
}

// MARK: - 消息行（分组）

/// 聊天列表里的一行：单条消息，或合并后的「处理过程」分组。
/// 消息列表的派生数据缓存。
final class ListCache {
    var key = ""
    var visible: [Bubble] = []
    var userTurns: [Bubble] = []
    var rows: [ChatRow] = []
}

enum ChatRow: Identifiable {
    case bubble(Bubble)
    case group(ProcessGroup)
    /// 超出渲染上限时折叠的历史条数。
    case loadEarlier(Int)

    var id: String {
        switch self {
        case .bubble(let b): return b.id.uuidString
        case .group(let g): return g.id
        case .loadEarlier: return "load-earlier"
        }
    }
}

/// 连续同类处理块合并成的分组（思考 / 工具）。
struct ProcessGroup: Identifiable {
    enum Kind {
        case thinking
        case tools
    }
    let id: String
    let kind: Kind
    let bubbles: [Bubble]

    var title: String {
        switch kind {
        case .thinking: return "思考"
        case .tools: return "工具调用"
        }
    }

    /// 分组摘要：条数 + 最后一条的片段。
    var summary: String {
        let last = bubbles.last?.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snippet = last.count > 44 ? String(last.prefix(44)) + "…" : last
        return bubbles.count > 1 ? "\(bubbles.count) 步 · \(snippet)" : snippet
    }
}

// MARK: - 滚动位置观测

/// 底部锚点在滚动坐标系里的位置（用于判断是否已贴底）。
private struct BottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// 滚动内容高度。
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 视口高度。
private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 命令面板条目

extension ChatView {
    /// ⌘K 面板的全部条目：会话、动作、提示词。
    var paletteItems: [PaletteItem] {
        var items: [PaletteItem] = []

        // 会话
        for c in convos.conversations {
            let count = c.bubbles.count
            var sub = count == 0 ? "空对话" : "\(count) 条消息"
            if c.inputTokens + c.outputTokens > 0 {
                sub += " · ↑\(ConversationListView.short(c.inputTokens)) ↓\(ConversationListView.short(c.outputTokens))"
            }
            items.append(PaletteItem(
                group: "会话",
                title: c.title,
                subtitle: sub,
                icon: "bubble.left.and.bubble.right"
            ) {
                convos.currentID = c.id
            })
        }

        // 动作
        items.append(PaletteItem(group: "动作", title: "新建对话", subtitle: "", icon: "plus") {
            model.newConversation()
        })
        items.append(PaletteItem(group: "动作", title: "清空当前对话", subtitle: "仅清空可见消息",
                                 icon: "trash") {
            model.clear()
        })
        items.append(PaletteItem(group: "动作", title: "筛选消息", subtitle: "在当前对话中搜索关键字",
                                 icon: "line.3.horizontal.decrease.circle") {
            showFilter = true
        })
        items.append(PaletteItem(group: "动作", title: "切换模型与思考强度",
                                 subtitle: store.currentModelLabel, icon: "cube") {
            ModelPopupState.shared.isOpen = true
        })
        items.append(PaletteItem(group: "动作", title: "选择工作目录",
                                 subtitle: convos.current?.workingDirectory ?? "使用默认目录",
                                 icon: "folder") {
            pickWorkingDirectory()
        })
        items.append(PaletteItem(group: "动作", title: "重新加载 MCP 服务器",
                                 subtitle: "已加载 \(MCPManager.shared.loadedToolCount) 个工具",
                                 icon: "server.rack") {
            MCPManager.shared.reload()
        })

        // 设置分区
        for section in SettingsSection.allCases {
            items.append(PaletteItem(group: "设置", title: section.title,
                                     subtitle: "打开设置中的「\(section.title)」",
                                     icon: section.icon) {
                SettingsNavigator.shared.open(section)
                onOpenSettings()
            })
        }

        // 提示词
        for p in prompts {
            items.append(PaletteItem(group: "提示词", title: p.title,
                                     subtitle: "插入到输入框", icon: "text.badge.plus") {
                model.input = p.body
                focused = true
            })
        }

        return items
    }
}

extension ChatView {
    /// 从当前气泡处创建分支对话并切换过去。
    ///
    /// 新对话包含该条及之前的全部消息，并继承原对话的工作目录；原对话保持不变。
    func branchHere(_ bubble: Bubble) {
        // 界面气泡与持久化气泡一一对应（同样的顺序与数量），因此用界面下标即可。
        guard let conversationID = convos.currentID,
              let index = model.bubbles.firstIndex(where: { $0.id == bubble.id })
        else { return }
        _ = convos.branch(from: conversationID, upto: index)
    }
}

// MARK: - 跨对话消息搜索

extension ChatView {
    /// 在所有对话的消息正文里搜索 `query`，返回可跳转的条目。
    ///
    /// 上限 20 条，跳过思考/工具块（噪音太大），命中处生成带上下文的片段。
    func searchMessages(_ query: String, limit: Int = 20) -> [PaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return [] }

        var hits: [PaletteItem] = []
        for conversation in convos.conversations {
            for (index, bubble) in conversation.bubbles.enumerated() {
                guard bubble.role == "user" || bubble.role == "assistant" else { continue }
                let text = bubble.text
                guard let range = text.range(of: needle, options: .caseInsensitive) else { continue }
                let snippet = Self.snippet(text, around: range)
                let isUser = bubble.role == "user"
                let title = conversation.title.isEmpty ? "未命名对话" : conversation.title
                hits.append(PaletteItem(
                    group: "消息",
                    title: "\(isUser ? "你" : "Myna")：\(snippet)",
                    subtitle: title,
                    icon: isUser ? "person" : "sparkles"
                ) {
                    model.selectConversation(conversation.id, focusBubbleAt: index)
                })
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// 取命中位置前后各一段文字，压平换行。
    static func snippet(_ text: String, around range: Range<String.Index>,
                        before: Int = 24, after: Int = 60) -> String {
        let start = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex)
            ?? text.endIndex
        var piece = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start != text.startIndex { piece = "…" + piece }
        if end != text.endIndex { piece += "…" }
        return piece
    }
}

// MARK: - 用户消息导航轨

extension ChatView {
    /// 当前会话里的用户消息（轮次），按出现顺序。
    var userTurns: [Bubble] {
        refreshListCache()
        return listCache.userTurns
    }

    /// 滚动进度（0…1），用于高亮当前轮次。
    private var scrollProgress: Double {
        let scrollable = max(1, contentBottomY - viewportHeight)
        return min(1, max(0, Double(scrollOffset / scrollable)))
    }

    /// 左侧纵向导航轨：每条用户消息一个刻度，点击跳转；悬停显示该轮 prompt 预览。
    ///
    /// 轨道本体是 AppKit 视图（见 `TurnRail`），避免预览出现导致 SwiftUI 重建、
    /// 进而丢失 hover 跟踪区（那会让预览无法切换到其它刻度）。
    @ViewBuilder
    func turnRail(_ proxy: ScrollViewProxy) -> some View {
        let turns = userTurns
        let active = pinnedTurnIndex
            ?? (turns.isEmpty ? 0 : min(turns.count - 1, Int(scrollProgress * Double(turns.count))))
        let natural = TurnRail.height(for: turns.count)
        let cap = max(80, viewportHeight - 40)
        let railHeight = min(natural, cap)
        ScrollView(.vertical, showsIndicators: false) {
        TurnRail(
            count: turns.count,
            activeIndex: turns.isEmpty ? 0 : active,
            accent: NSColor(theme.accent),
            onHover: { index, visibleY in
                if let index { showTurnPreview(index, visibleY: visibleY) } else { scheduleHideTurnPreview() }
            },
            onSelect: { index in
                guard index < turns.count else { return }
                // 点击后固定高亮该刻度：滚动进度是线性近似，跳转后未必落在同一刻度
                pinnedTurnIndex = index
                programmaticScrollUntil = Date().addingTimeInterval(0.6)
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(turns[index].id, anchor: .top)
                }
            }
        )
        .frame(width: TurnRail.width, height: natural)
        .contentShape(Rectangle())
        }
        .frame(width: TurnRail.width, height: railHeight)
        .scrollIndicators(.never)
    }

    static let tickHeight = TurnRail.tickHeight
    static let tickSpacing = TurnRail.tickSpacing

    /// 悬停某个刻度：立即切换预览到该轮。
    private func showTurnPreview(_ index: Int, visibleY: CGFloat? = nil) {
        previewHideWork?.cancel()
        previewHideWork = nil
        if let visibleY { previewTickY = visibleY }
        if index != previewTurnIndex {
            previewHeight = 0
            previewTextHeight = 0
        }
        hoveredTickIndex = index
        previewTurnIndex = index
    }

    /// 离开刻度或卡片：延迟收起，留出把光标移入卡片（滚动）的时间。
    private func scheduleHideTurnPreview() {
        previewHideWork?.cancel()
        let item = DispatchWorkItem {
            hoveredTickIndex = nil
            if !hoveringPreview { previewTurnIndex = nil }
        }
        previewHideWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// 第 index 个刻度的中心 Y（相对消息区顶部）。


    /// 预览卡片：竖向以刻度为中心，超出视口时自动收进可视范围。
    @ViewBuilder
    func turnPreviewCard(_ turns: [Bubble]) -> some View {
        if let index = previewTurnIndex, index < turns.count {
            // 轨道可能被裁短并滚动，用轨道上报的**可视区**坐标，避免预览偏离窗口
            let center = 12 + previewTickY
            // 卡片高度**只由内容决定**（上限 160 的滚动区），位置再按边界夹取。
            // 之前按「到边界的距离」限制高度，导致中间的卡片被拉到整窗口高度。
            let cardHeight = previewHeight > 0 ? previewHeight : 120
            let top = min(max(4, center - cardHeight / 2),
                          max(4, viewportHeight - cardHeight - 4))
            VStack(alignment: .leading, spacing: 4) {
                Text("第 \(index + 1) 轮")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                ScrollView {
                    Text(turns[index].text)
                        .font(theme.smallFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { previewTextHeight = g.size.height }
                                .onChange(of: g.size.height) { previewTextHeight = $0 }
                        })
                }
                // 内容短时贴合内容，长时（>160）才出现滚动
                .frame(height: min(max(18, previewTextHeight), 160))
            }
            .padding(8)
            .frame(width: 280, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.bubbleStroke, lineWidth: 1))
            .modifier(OptionalShadow(theme: theme, radius: 10, y: 3, opacity: 0.25))
            .background(GeometryReader { g in
                Color.clear.onAppear { previewHeight = g.size.height }
                    .onChange(of: g.size.height) { previewHeight = $0 }
            })
            .offset(y: top)
            .padding(.leading, 26)
            .onHover { inside in
                hoveringPreview = inside
                // 移入卡片时保持当前预览并取消收起；移出则安排收起
                if inside { previewHideWork?.cancel() } else { scheduleHideTurnPreview() }
            }
        }
    }

    /// 悬停时展示该轮提问的摘要。
    static func turnPreview(_ text: String, index: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
        return "第 \(index) 轮：\(snippet)"
    }
}

// MARK: - 处理过程分组

extension ChatView {
    /// 分组默认是否展开：运行中就展开（便于看进度），结束后按设置收起。
    private func groupExpanded(_ g: ProcessGroup) -> Bool {
        if let override = model.groupOverrides[g.id] { return override }
        return !(store.settings.collapseProcessingAfterRun && !model.busy)
    }

    /// 合并后的「思考 / 工具调用」分组行，可展开查看每一步。
    @ViewBuilder
    func groupRow(_ g: ProcessGroup) -> some View {
        let expanded = groupExpanded(g)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.groupOverrides[g.id] = !expanded
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    Image(systemName: g.kind == .thinking ? "brain" : "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(g.title)
                        .font(theme.tinyFont.weight(.semibold))
                    Text(g.summary)
                        .font(theme.tinyFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, theme.density.bubblePaddingH)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起处理过程" : "展开处理过程")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(g.bubbles) { b in
                        blockRow(b)
                    }
                }
                .padding(.top, 2)
            }
        }
        .background(g.kind == .thinking ? Color.purple.opacity(0.06) : theme.toolBubble)
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .stroke(theme.bubbleStroke, lineWidth: 1))
        .cornerRadius(theme.cornerRadius)
        .id(g.id)
    }
}

/// 可按设置关闭的阴影修饰符（性能模式下直接省略，避免每帧绘制模糊）。
struct OptionalShadow: ViewModifier {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double
    let enabled: Bool

    init(theme: ChatTheme, radius: CGFloat, y: CGFloat, opacity: Double, enabled: Bool = true) {
        self.radius = radius
        self.y = y
        self.opacity = opacity
        self.enabled = enabled
    }

    func body(content: Content) -> some View {
        let on = enabled && !ReduceEffects.isOn
        return content.shadow(color: on ? .black.opacity(opacity) : .clear, radius: on ? radius : 0, y: on ? y : 0)
    }
}

/// 全局「关闭阴影与动画」标志。
///
/// SwiftUI 的 `.shadow` 会每帧做一次离屏模糊；把开关放在这里，修饰符不必逐层传递设置。
enum ReduceEffects {
    @MainActor static var isOn = false
}


/// 只在键变化时重新求值内容的行包装。
///
/// SwiftUI 的 `EquatableView` 需要内容类型本身可比较；这里的行视图由多个修饰符拼成，
/// 类型无法手写相等，因此改为比较一个字符串键。
struct EquatableRow<Content: View>: View, Equatable {
    let key: String
    @ViewBuilder var content: () -> Content

    static func == (lhs: EquatableRow<Content>, rhs: EquatableRow<Content>) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View { content() }
}

