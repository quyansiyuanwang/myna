import SwiftUI
import AppKit
import PiKit

struct Bubble: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String
    let date = Date()
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var bubbles: [Bubble] = []
    @Published var input = ""
    @Published var busy = false
    @Published var isRecording = false
    @Published var streaming = ""
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

    private var settings: AppSettings { SettingsStore.shared.settings }

    init() {
        agent.onDelta = { [weak self] chunk in
            DispatchQueue.main.async { self?.streaming += chunk }
        }
        agent.onTool = { [weak self] name, result in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.streaming.isEmpty {
                    self.bubbles.append(Bubble(role: .assistant, text: self.streaming))
                    self.streaming = ""
                }
                if SettingsStore.shared.settings.showToolCalls {
                    self.bubbles.append(Bubble(role: .tool, text: "\(name) → \(result)"))
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
                let shouldSend = SettingsStore.shared.settings.autoSendOnSilence || self.pendingAutoSend
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
        pendingAutoSend = false
        if isRecording { speech.stop() }
        send()
    }

    func send() {
        if isRecording { speech.stop() }          // 发送前强制关麦克风
        Speaker.shared.stop()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        input = ""
        cancelling = false
        bubbles.append(Bubble(role: .user, text: text))
        busy = true
        streaming = ""
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
        busy = false
    }

    private func finishRun(answer: String) {
        let finalText = streaming.isEmpty ? answer : streaming
        if !streaming.isEmpty {
            bubbles.append(Bubble(role: .assistant, text: streaming))
            streaming = ""
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
        let agent = PackageRuntime.makeAgent(settings)
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
                String(s.maxTokens), String(s.temperature),
                String(s.topP), String(s.frequencyPenalty), String(s.presencePenalty),
                String(s.maxRetries),
                s.disabledTools.sorted().joined(separator: ",")].joined(separator: "\u{1F}")
    }

    private func handlePackageEvent(_ event: AgentEvent) {
        guard !cancelling else { return }
        switch event {
        case .messageUpdate(_, let update):
            if case .textDelta(let delta) = update { streaming += delta }

        case .toolExecutionStart(_, let name, let arguments):
            if !streaming.isEmpty {
                bubbles.append(Bubble(role: .assistant, text: streaming))
                streaming = ""
            }
            if settings.showToolCalls {
                let args = PackageRuntime.describe(arguments)
                bubbles.append(Bubble(role: .tool, text: args.isEmpty ? name : "\(name) \(args)"))
            }

        case .toolExecutionEnd(_, let name, let result, let isError):
            if settings.showToolCalls {
                let text = PackageRuntime.text(of: result.content)
                bubbles.append(Bubble(role: isError ? .error : .tool, text: "\(name) → \(text)"))
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
                self.bubbles.append(Bubble(role: .error, text: "需要「麦克风」和「语音识别」权限，请在 系统设置 → 隐私与安全性 中授权 AiSiri。"))
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
    var onOpenSettings: () -> Void = {}
    @FocusState private var focused: Bool

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
                Text("AiSiri").font(.system(size: 13, weight: .semibold))
                Text(statusText).font(theme.tinyFont).foregroundColor(.secondary)
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
            Button { onOpenSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("设置")
            Button { model.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("清空对话")
        }
        .padding(.horizontal, theme.density.contentPadding)
        .padding(.vertical, 8)
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

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.density.rowSpacing) {
                    if model.bubbles.isEmpty && model.streaming.isEmpty && !model.busy {
                        emptyState
                    }
                    ForEach(model.bubbles) { b in
                        messageRow(b, streaming: false)
                    }
                    if !model.streaming.isEmpty {
                        messageRow(Bubble(role: .assistant, text: model.streaming), streaming: true)
                            .id("streaming")
                    }
                    if model.busy && model.streaming.isEmpty {
                        thinkingRow
                    }
                }
                .padding(theme.density.contentPadding)
            }
            .onChange(of: model.bubbles.count) { _ in
                guard store.settings.autoScroll else { return }
                if let last = model.bubbles.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: model.streaming) { _ in
                guard store.settings.autoScroll else { return }
                withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundColor(theme.accent)
                    Text("你好，我是 AiSiri").font(.system(size: 15, weight: .semibold))
                }
                Text("直接说话或打字即可。我由大模型驱动，也能操作这台 Mac。")
                    .font(theme.smallFont).foregroundColor(.secondary)
            }
            .padding(.top, 16)

            Text("试试这些").font(theme.tinyFont).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { model.useSuggestion(s) } label: {
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

    private func messageRow(_ b: Bubble, streaming: Bool) -> some View {
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
                if isUser { Button("重新填入输入框") { model.useSuggestion(b.text) } }
            }
    }

    private func bubbleBackground(_ role: ChatRole) -> Color {
        switch role {
        case .user: return theme.userBubble
        case .tool: return theme.toolBubble
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

                TextField(model.isRecording ? "录音中，回车结束并发送" : "输入，或按快捷键说话",
                          text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.bodyFont)
                    .lineLimit(1...6)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.bubbleStroke))
                    .cornerRadius(10)
                    .focused($focused)
                    .onSubmit { model.submit() }

                Button { model.submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSend ? theme.accent : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .help(sendHint)
            }
            .padding(.horizontal, theme.density.contentPadding)
            .padding(.vertical, 8)
        }
    }

    private var canSend: Bool {
        !model.busy && (!model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isRecording)
    }

    private var sendHint: String {
        store.settings.sendOnEnter ? "回车发送（⇧回车换行）" : "⌘回车发送"
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
