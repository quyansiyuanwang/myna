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
    @Published var bubbles: [Bubble] = [] {
        didSet { syncConversation() }
    }
    @Published var input = ""
    @Published var busy = false
    @Published var isRecording = false
    @Published var streaming = ""
    @Published var streamingStart: Date?
    @Published var thinking = ""
    /// 折叠区块的手动展开/收起覆盖（默认值来自设置）
    @Published var blockOverrides: [UUID: Bool] = [:]
    @Published var liveTranscript = ""
    /// 窗口是否可见（不可见时不自动接听）
    @Published var windowVisible = false

    /// 内置兜底运行时（手写流式客户端 + 工具循环）
    let agent = BuiltinAgent()
    let speech = SpeechRecognizer()

    /// Swift 包运行时（PiAI + PiAgentCore），运行期零 Node
    private var packageAgent: Agent?
    private var packageUnsubscribe: (() -> Void)?
    private var packageSignature = ""
    private var packageTask: Task<Void, Never>?
    private var builtinTask: Task<Void, Never>?
    private var cancelling = false
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
        agent.onDelta = { [weak self] chunk in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.streamingStart == nil { self.streamingStart = Date() }
                self.streaming += chunk
            }
        }
        agent.onThinking = { [weak self] chunk in
            DispatchQueue.main.async { self?.thinking += chunk }
        }
        agent.onTool = { [weak self] name, result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.flushThinking()
                if !self.streaming.isEmpty {
                    self.bubbles.append(Bubble(role: .assistant, text: self.streaming, date: self.streamingStart ?? Date()))
                    self.streaming = ""
                    self.streamingStart = nil
                }
                self.bubbles.append(Bubble(role: .tool, text: "\(name) → \(result)"))
                if SettingsStore.shared.settings.speakToolResults,
                   SettingsStore.shared.settings.voiceEnabled, !result.isEmpty {
                    Speaker.shared.say(result)
                }
            }
        }
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
        } else {
            if store.currentID == nil { store.currentID = store.conversations.first?.id }
            load(store.current)
        }
    }

    // MARK: - 会话

    var conversations: [Conversation] { store.conversations }
    var currentConversationID: UUID? { store.currentID }

    /// 把当前气泡写回会话（气泡变化时自动调用）。
    private func syncConversation() {
        if store.currentID == nil { store.create() }
        guard let id = store.currentID,
              var c = store.conversations.first(where: { $0.id == id }) else { return }
        c.bubbles = bubbles.map { StoredBubble(role: $0.role.rawValue, text: $0.text, date: $0.date) }
        if c.title == "新对话", !c.bubbles.isEmpty {
            c.title = Conversation.derivedTitle(from: c.bubbles)
        }
        c.updatedAt = Date()
        store.update(c)
    }

    func newConversation() {
        store.create()
        load(nil)
    }

    func selectConversation(_ id: UUID) {
        guard id != store.currentID else { return }
        store.currentID = id
        load(store.conversations.first { $0.id == id })
    }

    func deleteConversation(_ id: UUID) {
        let wasCurrent = store.currentID == id
        store.delete(id)
        if store.conversations.isEmpty { store.create() }
        if wasCurrent { load(store.current) }
    }

    func renameCurrent(_ title: String) {
        if let id = store.currentID { store.rename(id, to: title) }
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

    /// 把一段会话载入界面，并重建两个运行时的上下文。
    private func load(_ c: Conversation?) {
        cancel()
        speech.stop()
        bubbles = (c?.bubbles ?? []).map {
            Bubble(role: ChatRole.from($0.role), text: $0.text, date: $0.date)
        }
        streaming = ""
        streamingStart = nil
        liveTranscript = ""
        cancelling = false
        // 内置运行时：重建 [[String: Any]] 历史
        agent.settings = settings
        agent.reset()
        for m in c?.bubbles ?? [] where m.role == "user" || m.role == "assistant" {
            agent.messages.append(["role": m.role, "content": m.text])
        }
        // 包运行时：注入 Message 历史
        if usePackageRuntime {
            let msgs = c?.agentMessages(model: settings.model) ?? []
            let a = ensurePackageAgent()
            Task { await a.setTranscript(msgs) }
        } else if let packageAgent {
            Task { await packageAgent.reset() }
        }
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
        guard !text.isEmpty, !busy else { return }
        input = ""
        cancelling = false
        bubbles.append(Bubble(role: .user, text: text))
        busy = true
        streaming = ""
        streamingStart = nil
        sampling.update(settings)
        Speaker.shared.configure(settings)
        if usePackageRuntime { sendViaPackage(text) } else { sendViaBuiltin(text) }
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

    /// 运行时选择：`auto` / `package` 走 Swift 包；`builtin` 走内置实现。
    private var usePackageRuntime: Bool {
        settings.agentRuntime == "builtin" ? false : true
    }

    /// 取消当前回答/工具调用；两条路径都会中止。
    func cancel() {
        guard busy else { return }
        cancelling = true
        Speaker.shared.stop()
        builtinTask?.cancel()
        packageTask?.cancel()
        if let a = packageAgent { Task { await a.abort() } }
        streaming = ""
        streamingStart = nil
        thinking = ""
        busy = false
    }

    /// 把累积的思考内容落成一条可折叠区块。
    private func flushThinking() {
        let t = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        thinking = ""
        guard !t.isEmpty else { return }
        bubbles.append(Bubble(role: .thinking, text: t))
    }

    private func finishRun(answer: String) {
        flushThinking()
        let finalText = streaming.isEmpty ? answer : streaming
        if !streaming.isEmpty {
            bubbles.append(Bubble(role: .assistant, text: streaming, date: streamingStart ?? Date()))
            streaming = ""
            streamingStart = nil
        } else if !answer.isEmpty {
            bubbles.append(Bubble(role: .assistant, text: answer))
        }
        if settings.voiceEnabled && !finalText.isEmpty { Speaker.shared.say(finalText) }
        busy = false
        if settings.continuousMode && !settings.voiceEnabled { startVoice() }
    }

    // MARK: - Swift 包运行时（PiAI + PiAgentCore）

    /// 设置（模型 / 系统提示 / 工具开关等）变化时重建 Agent；否则复用同一实例以保留上下文。
    private func ensurePackageAgent() -> Agent {
        let sig = packageSignatureValue
        if let agent = packageAgent, packageSignature == sig { return agent }
        packageUnsubscribe?()
        let agent = PackageRuntime.makeAgent(settings, sampling: sampling)
        packageUnsubscribe = agent.subscribe { [weak self] event in
            Task { @MainActor in self?.handlePackageEvent(event) }
        }
        packageAgent = agent
        packageSignature = sig
        return agent
    }

    private var packageSignatureValue: String {
        let s = settings
        return [s.model, s.baseURL, s.systemPrompt, s.apiKey,
                String(s.maxRetries),
                s.disabledTools.sorted().joined(separator: ",")].joined(separator: "\u{1F}")
    }

    private func handlePackageEvent(_ event: AgentEvent) {
        guard !cancelling else { return }
        switch event {
        case .messageUpdate(_, let update):
            if case .thinkingDelta(let delta) = update {
                thinking += delta
            }
            if case .textDelta(let delta) = update {
                if streamingStart == nil { streamingStart = Date() }
                streaming += delta
            }

        case .toolExecutionStart(_, let name, let arguments):
            flushThinking()
            if !streaming.isEmpty {
                bubbles.append(Bubble(role: .assistant, text: streaming, date: streamingStart ?? Date()))
                streaming = ""
                streamingStart = nil
            }
            let args = PackageRuntime.describe(arguments)
            bubbles.append(Bubble(role: .tool, text: args.isEmpty ? name : "\(name) \(args)"))

        case .toolExecutionEnd(_, let name, let result, let isError):
            let text = PackageRuntime.text(of: result.content)
            bubbles.append(Bubble(role: isError ? .error : .tool, text: "\(name) → \(text)"))
            if settings.speakToolResults, settings.voiceEnabled, !text.isEmpty {
                Speaker.shared.say(text)
            }

        case .agentEnd(let messages):
            finishRun(answer: PackageRuntime.finalAnswer(in: messages))

        default:
            break
        }
    }

    private func sendViaPackage(_ text: String) {
        let agent = ensurePackageAgent()
        packageTask = Task { [weak self] in
            do {
                try await agent.prompt(text)
            } catch {
                guard let self, !self.cancelling else { return }
                if error is CancellationError || Task.isCancelled { return }
                self.streaming = ""
                self.bubbles.append(Bubble(role: .error, text: error.localizedDescription))
                self.busy = false
            }
        }
    }

    // MARK: - 内置兜底运行时

    private func sendViaBuiltin(_ text: String) {
        agent.settings = settings
        builtinTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.agent.ask(text)
                if !self.cancelling { self.finishRun(answer: answer) }
            } catch {
                guard !self.cancelling else { return }
                if error is CancellationError || Task.isCancelled { return }
                self.streaming = ""
                self.bubbles.append(Bubble(role: .error, text: error.localizedDescription))
                self.busy = false
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
            } else {
                self.bubbles.append(Bubble(role: .error, text: "需要「麦克风」和「语音识别」权限，请在 系统设置 → 隐私与安全性 中授权 Myna。"))
            }
        }
    }

    func clear() {
        cancel()
        speech.stop()
        bubbles.removeAll()
        streaming = ""
        liveTranscript = ""
        cancelling = false
        agent.settings = settings
        agent.reset()
        if let packageAgent { Task { await packageAgent.reset() } }
    }
}

// MARK: - 聊天界面

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var convos = ConversationStore.shared
    var onOpenSettings: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var liveThinkingExpanded: Bool?
    @State private var showConversations = false

    private var theme: ChatTheme { ChatTheme(store.settings) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            inputBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(theme.accent)
        .onAppear { focused = true }
    }

    // MARK: 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: store.settings.menuBarIcon)
                .font(.system(size: 15))
                .foregroundColor(theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Myna").font(.system(size: 13, weight: .semibold))
                if model.isRecording || model.busy {
                    Text(statusText).font(theme.tinyFont).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        modelMenu
                        Text("· \(runtimeLabel)").font(theme.tinyFont).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()

            compactToggle(icon: "speaker.wave.2.fill", on: store.settings.voiceEnabled,
                          help: "朗读回答") { store.settings.voiceEnabled.toggle() }
            compactToggle(icon: "infinity", on: store.settings.continuousMode,
                          help: "连续对话：朗读完自动接着听") { store.settings.continuousMode.toggle() }

            if model.busy {
                Button { model.cancel() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.borderless).foregroundColor(.red).help("停止当前回答")
            }
            conversationMenu
            Button { onOpenSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("设置")
            Button { model.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("清空当前对话")
        }
        .padding(.horizontal, theme.density.contentPadding)
        .padding(.vertical, 8)
    }

    /// 顶栏模型快捷切换菜单。
    private var modelMenu: some View {
        Menu {
            ForEach(ModelCatalog.suggestions(for: store.settings.baseURL, current: store.settings.model), id: \.self) { m in
                Button {
                    store.settings.model = m
                } label: {
                    if m == store.settings.model { Label(m, systemImage: "checkmark") } else { Text(m) }
                }
            }
            Divider()
            Button("更多模型设置…") { onOpenSettings() }
        } label: {
            HStack(spacing: 3) {
                Text(store.settings.model).font(theme.tinyFont)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .foregroundColor(theme.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var statusText: String {
        if model.isRecording { return "正在聆听…（再按一次快捷键结束）" }
        if model.busy { return "思考中…" }
        return "\(store.settings.model) · \(runtimeLabel)"
    }

    private var runtimeLabel: String {
        switch store.settings.agentRuntime {
        case "builtin": return "内置运行时"
        case "package": return "Swift 包运行时"
        default: return "自动"
        }
    }

    private func compactToggle(icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(on ? theme.accent : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: 消息列表

    /// 按显示设置过滤后的消息（切换开关会立即影响已有消息）。
    private var visibleBubbles: [Bubble] {
        model.bubbles.filter { b in
            switch b.role {
            case .thinking: return store.settings.showThinking
            case .tool: return store.settings.showToolCalls
            default: return true
            }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.density.rowSpacing) {
                    if visibleBubbles.isEmpty && model.streaming.isEmpty && !model.busy {
                        emptyState
                    }
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
            .onChange(of: model.bubbles.count) { _ in
                guard store.settings.autoScroll else { return }
                if let last = visibleBubbles.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: model.streaming) { _ in
                guard store.settings.autoScroll else { return }
                withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
            }
            .onChange(of: model.thinking) { _ in
                guard store.settings.autoScroll, store.settings.showThinking else { return }
                withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
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
            .padding(.top, 16)

            Text("试试这些").font(theme.tinyFont).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { model.useSuggestion(s); focused = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars").font(.system(size: 10))
                            Text(s).font(theme.smallFont).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.bubbleStroke))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
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
            MessageBody(text: b.text, markdown: theme.markdown, font: theme.smallFont)
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
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.bubbleStroke))
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
        return HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 32) }

            if !isUser && theme.showAvatars { avatar(b.role) }

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

                bubbleContent(b, streaming: streaming)
            }

            if !isUser && theme.showAvatars { Spacer(minLength: 0) }
            if isUser { avatar(b.role) }
        }
        .id(b.id)
    }

    private func bubbleContent(_ b: Bubble, streaming: Bool) -> some View {
        let isUser = b.role == .user
        return MessageBody(text: b.text, markdown: theme.markdown && !isUser, font: theme.bodyFont)
            .foregroundColor(isUser ? .white : (b.role == .error ? .red : .primary))
            .padding(.horizontal, theme.density.bubblePaddingH)
            .padding(.vertical, theme.density.bubblePaddingV)
            .background(bubbleBackground(b.role))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.bubbleStroke)
            )
            .cornerRadius(theme.cornerRadius)
            .textSelection(.enabled)
            .contextMenu {
                Button("拷贝") { model.copy(b.text) }
                if isUser { Button("重新填入输入框") { model.useSuggestion(b.text); focused = true } }
            }
    }

    private func bubbleBackground(_ role: ChatRole) -> Color {
        switch role {
        case .user: return theme.userBubble
        case .tool: return theme.toolBubble
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
        VStack(spacing: 4) {
            if model.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundColor(.red)
                    Text(model.liveTranscript.isEmpty ? "正在聆听…" : model.liveTranscript)
                        .font(theme.smallFont)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                    Spacer()
                }
                .padding(.horizontal, theme.density.contentPadding)
                .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button { model.toggleMic() } label: {
                    Image(systemName: model.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 14))
                        .foregroundColor(model.isRecording ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help("点击说话；再次点击结束（不发送）。全局快捷键可随时开关录音")

                inputField()

                Button { model.submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSend ? theme.accent : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(sendHint)
            }
            .padding(.horizontal, theme.density.contentPadding)
            .padding(.vertical, 8)
        }
    }

    /// 输入框。`sendOnEnter` 开启时回车发送；关闭时不挂 onSubmit，回车换行、⌘回车发送。
    @ViewBuilder
    private func inputField() -> some View {
        let base = TextField(model.isRecording ? "录音中，回车结束并发送" : "输入，或按快捷键说话",
                             text: $model.input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(theme.bodyFont)
            .lineLimit(1...6)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.bubbleStroke))
            .cornerRadius(10)
            .focused($focused)
        if store.settings.sendOnEnter {
            base.onSubmit { model.submit() }
        } else {
            base
        }
    }

    private var canSend: Bool {
        !model.busy && (!model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isRecording)
    }

    private var sendHint: String {
        store.settings.sendOnEnter ? "回车发送（⇧回车换行）" : "⌘回车发送（回车换行）"
    }

    // MARK: - 会话菜单

    private var conversationMenu: some View {
        Button { showConversations.toggle() } label: {
            Image(systemName: "list.bullet")
        }
        .buttonStyle(.borderless)
        .help("会话")
        .popover(isPresented: $showConversations, arrowEdge: .bottom) {
            ConversationListView(model: model, isPresented: $showConversations)
        }
    }
}

// MARK: - 消息正文（支持 Markdown 与代码块）

private struct MessageBody: View {
    let text: String
    let markdown: Bool
    let font: Font

    var body: some View {
        if markdown {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let s):
                        if let attr = try? AttributedString(
                            markdown: s,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                        ) {
                            Text(attr).font(font)
                        } else {
                            Text(s).font(font)
                        }
                    case .code(let s):
                        Text(s)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
                            .cornerRadius(6)
                            .textSelection(.enabled)
                    }
                }
            }
        } else {
            Text(text).font(font)
        }
    }

    private enum Segment {
        case text(String)
        case code(String)
    }

    /// 按 ``` 围栏切分，围栏内为代码块。
    private var segments: [Segment] {
        var result: [Segment] = []
        var buffer = ""
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(buffer.trimmingCharacters(in: .newlines)))
                    buffer = ""
                } else if !buffer.isEmpty {
                    result.append(.text(buffer))
                    buffer = ""
                }
                inCode.toggle()
            } else {
                buffer += (buffer.isEmpty ? "" : "\n") + line
            }
        }
        if !buffer.isEmpty { result.append(inCode ? .code(buffer) : .text(buffer)) }
        return result.isEmpty ? [.text(text)] : result
    }
}
