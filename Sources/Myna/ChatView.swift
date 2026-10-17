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
    @Published var streaming = ""
    @Published var streamingStart: Date?
    @Published var thinking = ""
    /// 正在运行的会话 id（前台 + 后台）
    @Published var runningConversations: Set<UUID> = []
    /// 折叠区块的手动展开/收起覆盖（默认值来自设置）
    @Published var blockOverrides: [UUID: Bool] = [:]
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

    // MARK: - 运行上下文

    /// 取得（必要时创建）某个会话的运行上下文，并接好内置运行时的回调。
    func context(for id: UUID) -> RunContext {
        if let ctx = contexts[id] { return ctx }
        let ctx = RunContext(conversationID: id, builtinAgent: BuiltinAgent())
        if let c = store.conversations.first(where: { $0.id == id }) {
            ctx.bubbles = c.bubbles.map { Bubble(role: ChatRole.from($0.role), text: $0.text, date: $0.date) }
        }
        wireBuiltinCallbacks(ctx)
        rebuildHistory(ctx)
        contexts[id] = ctx
        return ctx
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
        if isCurrent(ctx) {
            streaming = value
            streamingStart = start
        }
    }

    private func setThinking(_ value: String, for ctx: RunContext) {
        ctx.thinking = value
        if isCurrent(ctx) { thinking = value }
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
        setThinking("", for: ctx)
        guard !t.isEmpty else { return }
        appendBubble(Bubble(role: .thinking, text: t), to: ctx)
    }

    private func finishRun(answer: String, for ctx: RunContext) {
        guard !ctx.cancelling else { return }
        flushThinking(for: ctx)
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
    }

    // MARK: - Swift 包运行时（PiAI + PiAgentCore）

    /// 设置（模型 / 系统提示 / 工具开关等）变化时重建 Agent；否则复用同一实例以保留上下文。
    private func ensurePackageAgent(for ctx: RunContext) async -> Agent {
        let sig = packageSignatureValue
        if let agent = ctx.packageAgent, ctx.signature == sig { return agent }
        ctx.packageUnsubscribe?()
        let previous = ctx.packageAgent
        let agent = PackageRuntime.makeAgent(settings, sampling: sampling)
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

    private var packageSignatureValue: String {
        let s = settings
        return [s.model, s.baseURL, s.systemPrompt, s.apiKey, s.api,
                s.reasoningEffort, String(s.thinkingBudget),
                String(s.maxRetries), String(s.maxToolRounds),
                String(s.unlimitedToolRounds),
                String(s.codingMode), s.workingDirectory,
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
            if !ctx.streaming.isEmpty {
                appendBubble(Bubble(role: .assistant, text: ctx.streaming, date: ctx.streamingStart ?? Date()), to: ctx)
                setStreaming("", start: nil, for: ctx)
            }
            let args = PackageRuntime.describe(arguments)
            appendBubble(Bubble(role: .tool, text: args.isEmpty ? name : "\(name) \(args)"), to: ctx)

        case .toolExecutionEnd(_, let name, let result, let isError):
            let text = PackageRuntime.text(of: result.content)
            appendBubble(Bubble(role: isError ? .error : .toolResult, text: "\(name) → \(text)"), to: ctx)
            if isCurrent(ctx), settings.speakToolResults, settings.voiceEnabled, !text.isEmpty {
                Speaker.shared.say(text)
            }

        case .agentEnd(let messages):
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
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}
    var onResize: (CGSize) -> Void = { _ in }
    /// 拖拽结束时调用一次，用于把最终尺寸落盘
    var onResizeEnd: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var liveThinkingExpanded: Bool?
    @State private var showConversations = false
    @State private var showFilter = false
    @State private var filterQuery = ""
    @State private var showPrompts = false
    @State private var showModelControl = false
    @State private var dragBase: CGSize?
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
            if showModelControl {
                ModelControlPanel(theme: theme)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            inputBar
            if store.settings.resizablePanel {
                resizeStrip
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(theme.accent)
        .onAppear {
            focused = true
            prompts = LocalResources.prompts()
            // 调试/自动化：直接展开模型与思考强度面板（MYNA_DEBUG_MODEL_PANEL=1）
            if ProcessInfo.processInfo.environment["MYNA_DEBUG_MODEL_PANEL"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showModelControl = true }
            }
        }
        .onExitCommand {
            if editingBubble != nil {
                cancelEdit()
            } else if showModelControl {
                withAnimation(.easeInOut(duration: 0.18)) { showModelControl = false }
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
        .frame(height: 16)
        .padding(.trailing, 4)
        .padding(.bottom, 2)
    }

    /// 面板右下角拖拽调整尺寸的手柄；平时低调，悬停时显现。
    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.secondary)
            .opacity(hoverResize ? 0.75 : 0.25)
            .frame(width: 30, height: 16)
            .contentShape(Rectangle())
            .onHover { hoverResize = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // 以窗口当前的真实内容尺寸为基准，整个拖拽过程只取一次；
                        // 避免上一次带外缩放导致首帧跳变。
                        let base = dragBase ?? currentContentSize()
                        if dragBase == nil { dragBase = base }
                        onResize(CGSize(width: base.width + value.translation.width,
                                        height: base.height + value.translation.height))
                    }
                    .onEnded { _ in
                        dragBase = nil
                        onResizeEnd()
                    }
            )
            .help("拖拽调整窗口大小")
    }

    /// 当前承载视图的窗口内容尺寸，取不到时回退到设置里的尺寸。
    private func currentContentSize() -> CGSize {
        if let win = NSApp.keyWindow {
            return win.contentRect(forFrameRect: win.frame).size
        }
        return CGSize(width: store.settings.windowWidth, height: store.settings.windowHeight)
    }

    // MARK: 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: store.settings.menuBarIcon)
                .font(.system(size: 15))
                .foregroundColor(theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Myna").font(.system(size: 13, weight: .semibold))
                if model.isRecording || model.busy || backgroundRunningCount > 0 {
                    Text(statusText).font(theme.tinyFont).foregroundColor(.secondary)
                } else {
                    Text(runtimeLabel).font(theme.tinyFont).foregroundColor(.secondary)
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

            Button { showFilter.toggle() } label: { headerIcon("line.3.horizontal.decrease.circle", active: showFilter) }
                .buttonStyle(.plain).modifier(HoverHighlight()).help("筛选消息")
            conversationMenu
            Button { model.newConversation() } label: { headerIcon("plus") }
                .buttonStyle(.plain).modifier(HoverHighlight()).help("新建对话")
            Button { onOpenSettings() } label: { headerIcon("gearshape") }
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

    /// 除当前会话外，正在后台运行的会话数量。
    private var backgroundRunningCount: Int {
        model.runningConversations.filter { $0 != model.currentConversationID }.count
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
    private var visibleBubbles: [Bubble] {
        let q = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return model.bubbles.filter { b in
            switch b.role {
            case .thinking: if !store.settings.showThinking { return false }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.density.rowSpacing) {
                    ForEach(visibleBubbles) { b in
                        messageRow(b, streaming: false)
                    }
                    if !model.thinking.isEmpty && store.settings.showThinking {
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
                }
                .padding(theme.density.contentPadding)
            }
            .onChange(of: model.pendingScrollTarget) { target in
                guard let target else { return }
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    model.pendingScrollTarget = nil
                }
            }
            .onChange(of: model.bubbles.count) { _ in scrollToEnd(proxy) }
            .onChange(of: model.streaming) { _ in scrollToEnd(proxy) }
            .onChange(of: model.thinking) { _ in scrollToEnd(proxy) }
            .onChange(of: model.busy) { _ in scrollToEnd(proxy) }
        }
    }

    /// 滚动到最新内容。延后一个 runloop，确保新气泡已完成布局。
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard store.settings.autoScroll else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                if !model.streaming.isEmpty {
                    proxy.scrollTo("streaming", anchor: .bottom)
                } else if !model.thinking.isEmpty, store.settings.showThinking {
                    proxy.scrollTo("thinking", anchor: .bottom)
                } else if let last = visibleBubbles.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundColor(theme.accent)
                    Text("你好，我是 Myna").font(.system(size: 15, weight: .semibold))
                }
                Text("直接说话或打字即可。我由大模型驱动，也能操作这台 Mac。")
                    .font(theme.smallFont).foregroundColor(.secondary)
            }

            Text("试试这些").font(theme.tinyFont).foregroundColor(.secondary)
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
        if b.role.isCollapsible {
            blockRow(b)
        } else {
            bubbleRow(b, streaming: streaming)
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
            MessageBody(text: b.text, markdown: theme.markdown, size: theme.fontSize - 2, theme: theme)
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
            onEdit: isUser ? { beginEdit(b) } : nil
        )
        .padding(.top, 2)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .frame(width: isUser ? 62 : 42, alignment: isUser ? .trailing : .leading)
    }

    private func bubbleContent(_ b: Bubble, streaming: Bool) -> some View {
        let isUser = b.role == .user
        return MessageBody(text: b.text, markdown: theme.markdown && !isUser, size: theme.fontSize, theme: theme)
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
        let active = showModelControl
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { showModelControl.toggle() }
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
        showModelControl = false
        model.submit()
    }

    /// 点击面板以外的区域（标题栏 / 消息列表）时收起内联模型面板。
    private func dismissModelControl() {
        guard showModelControl else { return }
        withAnimation(.easeInOut(duration: 0.18)) { showModelControl = false }
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

private struct MessageBody: View {
    let text: String
    let markdown: Bool
    let size: CGFloat
    var theme: ChatTheme

    private var font: Font { .system(size: size) }

    var body: some View {
        if markdown {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .code(let code, let language):
                        CodeBlockView(code: code, language: language, size: size, theme: theme)
                    case .heading(let level, let s):
                        inline(s).font(.system(size: headingSize(level), weight: .semibold))
                    case .bullet(let s):
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").font(font)
                            inline(s)
                        }
                    case .ordered(let marker, let s):
                        HStack(alignment: .top, spacing: 6) {
                            Text(marker).font(font).foregroundColor(.secondary)
                            inline(s)
                        }
                    case .paragraph(let s):
                        inline(s)
                    }
                }
            }
        } else {
            Text(text).font(font)
        }
    }

    @ViewBuilder
    private func inline(_ s: String) -> some View {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr).font(font).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(s).font(font).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return size + 5
        case 2: return size + 3
        case 3: return size + 1
        default: return size
        }
    }

    // MARK: - 块级解析

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case bullet(String)
        case ordered(String, String)
        case code(String, String?)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    out.append(.code(code.joined(separator: "\n"), codeLanguage))
                    code = []
                    codeLanguage = nil
                } else {
                    flushParagraph()
                    let info = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = info.isEmpty ? nil : info
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let h = heading(trimmed) {
                flushParagraph()
                out.append(.heading(h.0, h.1))
                continue
            }
            if let b = bullet(trimmed) {
                flushParagraph()
                out.append(.bullet(b))
                continue
            }
            if let o = ordered(trimmed) {
                flushParagraph()
                out.append(.ordered(o.0, o.1))
                continue
            }
            paragraph.append(line)
        }
        if inCode, !code.isEmpty { out.append(.code(code.joined(separator: "\n"), codeLanguage)) }
        flushParagraph()
        return out.isEmpty ? [.paragraph(text)] : out
    }

    private func heading(_ s: String) -> (Int, String)? {
        let hashes = s.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = s.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private func bullet(_ s: String) -> String? {
        for p in ["- ", "* ", "+ "] where s.hasPrefix(p) {
            return String(s.dropFirst(p.count))
        }
        return nil
    }

    private func ordered(_ s: String) -> (String, String)? {
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber {
            digits.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !digits.isEmpty, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
        let afterMarker = s.index(after: idx)
        guard afterMarker < s.endIndex, s[afterMarker] == " " else { return nil }
        return ("\(digits).", String(s[s.index(after: afterMarker)...]))
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
