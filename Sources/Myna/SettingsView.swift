import SwiftUI
import AVFoundation
import AppKit

// MARK: - 分区

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, model, voice, chat, behavior, tools, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .model: return "模型"
        case .voice: return "语音"
        case .chat: return "对话"
        case .behavior: return "行为"
        case .tools: return "工具"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .model: return "cpu"
        case .voice: return "waveform"
        case .chat: return "bubble.left.and.bubble.right"
        case .behavior: return "slider.horizontal.3"
        case .tools: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @State private var section: SettingsSection? = .appearance

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 176)

            Divider()

            ScrollView {
                detail
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 720, height: 580)
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .appearance {
        case .appearance: AppearanceTab(store: store)
        case .model: ModelTab(store: store)
        case .voice: VoiceTab(store: store)
        case .chat: ChatTab(store: store)
        case .behavior: BehaviorTab(store: store)
        case .tools: ToolsTab(store: store)
        case .about: AboutTab()
        }
    }
}

// MARK: - 通用组件

private struct SectionBox<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(format(value)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            if step > 0 {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

// MARK: - 外观

private struct AppearanceTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("主题") {
                Picker("外观模式", selection: $store.settings.appearance) {
                    ForEach(AppearanceOption.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text("强调色").font(.system(size: 12))
                    HStack(spacing: 8) {
                        ForEach(AccentOption.allCases) { opt in
                            Circle()
                                .fill(opt.color)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(Color.primary.opacity(
                                        store.settings.accent == opt.rawValue ? 0.7 : 0.12),
                                        lineWidth: store.settings.accent == opt.rawValue ? 2 : 1)
                                )
                                .help(opt.label)
                                .onTapGesture { store.settings.accent = opt.rawValue }
                        }
                    }
                }
            }

            SectionBox("排版") {
                SliderRow(label: "字号", value: $store.settings.fontSize, range: 11...18, step: 1) {
                    "\(Int($0)) pt"
                }
                Picker("信息密度", selection: $store.settings.density) {
                    ForEach(DensityOption.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                SliderRow(label: "气泡圆角", value: $store.settings.bubbleCornerRadius, range: 4...20, step: 1) {
                    "\(Int($0))"
                }
                Toggle("显示头像与名称", isOn: $store.settings.showAvatars)
                Toggle("显示时间戳", isOn: $store.settings.showTimestamps)
                Toggle("渲染 Markdown（粗体、代码等）", isOn: $store.settings.markdownEnabled)
            }

            SectionBox("窗口") {
                SliderRow(label: "不透明度", value: $store.settings.windowOpacity, range: 0.7...1.0, step: 0.05) {
                    "\(Int($0 * 100))%"
                }
                SliderRow(label: "默认宽度", value: $store.settings.windowWidth, range: 380...900, step: 10) {
                    "\(Int($0))"
                }
                SliderRow(label: "默认高度", value: $store.settings.windowHeight, range: 480...1000, step: 10) {
                    "\(Int($0))"
                }
                Text("窗口尺寸在下次打开窗口时生效。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 模型

private struct ModelTab: View {
    @ObservedObject var store: SettingsStore
    @State private var testResult = ""
    @State private var testing = false

    private let presets: [(String, String, String)] = [
        ("DeepSeek", "https://api.deepseek.com", "deepseek-flash"),
        ("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"),
        ("Ollama", "http://localhost:11434/v1", "llama3.1"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("接口") {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { p in
                        Button(p.0) {
                            store.settings.baseURL = p.1
                            store.settings.model = p.2
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                TextField("API 地址", text: $store.settings.baseURL).textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $store.settings.apiKey).textFieldStyle(.roundedBorder)
                TextField("模型", text: $store.settings.model).textFieldStyle(.roundedBorder)
                HStack {
                    Button(testing ? "测试中…" : "测试连接") { test() }.disabled(testing)
                    Text(testResult).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                }
                Text("任何 OpenAI 兼容端点都可用（DeepSeek / OpenAI / Ollama 等）。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            SectionBox("运行时") {
                Picker("Agent 运行时", selection: $store.settings.agentRuntime) {
                    Text("自动").tag("auto")
                    Text("Swift 包（PiAI + PiAgentCore）").tag("package")
                    Text("内置").tag("builtin")
                }
                Text("Swift 包运行时直接链接 PiAI + PiAgentCore，运行期零 Node、零额外进程。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            SectionBox("生成参数") {
                SliderRow(label: "温度", value: $store.settings.temperature, range: 0...1.5, step: 0.1)
                SliderRow(label: "Top P", value: $store.settings.topP, range: 0...1, step: 0.05)
                SliderRow(label: "频率惩罚", value: $store.settings.frequencyPenalty, range: -2...2, step: 0.1)
                SliderRow(label: "存在惩罚", value: $store.settings.presencePenalty, range: -2...2, step: 0.1)
                HStack {
                    Text("最大 tokens").font(.system(size: 12))
                    Spacer()
                    Stepper("\(store.settings.maxTokens)", value: $store.settings.maxTokens, in: 256...131072, step: 256)
                        .labelsHidden()
                }
                HStack {
                    Text("失败重试次数").font(.system(size: 12))
                    Spacer()
                    Stepper("\(store.settings.maxRetries)", value: $store.settings.maxRetries, in: 0...6)
                        .labelsHidden()
                }
            }

            SectionBox("系统提示词") {
                TextEditor(text: $store.settings.systemPrompt)
                    .font(.system(size: 12))
                    .frame(height: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                Button("恢复默认提示词") { store.settings.systemPrompt = AppSettings.defaultSystemPrompt }
                    .controlSize(.small)
            }
        }
    }

    private func test() {
        testing = true; testResult = ""
        let s = store.settings
        Task {
            do {
                let client = DeepSeekClient(s)
                let msg = try await client.chat(messages: [["role": "user", "content": "ping，只回复 pong"]], tools: [])
                let text = (msg["content"] as? String) ?? "(空)"
                testResult = "✅ 连接成功：\(text.prefix(30))"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

// MARK: - 语音

private struct VoiceTab: View {
    @ObservedObject var store: SettingsStore

    private var voices: [AVSpeechSynthesisVoice] {
        let prefix = String(store.settings.voiceLanguage.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("朗读输出") {
                Toggle("朗读回答", isOn: $store.settings.voiceEnabled)
                Toggle("朗读工具执行结果", isOn: $store.settings.speakToolResults)
                Picker("语言", selection: $store.settings.voiceLanguage) {
                    Text("中文（普通话）").tag("zh-CN")
                    Text("中文（粤语）").tag("zh-HK")
                    Text("English (US)").tag("en-US")
                    Text("日本語").tag("ja-JP")
                }
                Picker("音色", selection: $store.settings.voiceName) {
                    Text("默认").tag("")
                    ForEach(voices, id: \.identifier) { v in Text(v.name).tag(v.identifier) }
                }
                SliderRow(label: "语速", value: $store.settings.voiceRate, range: 0.3...0.8, step: 0.05)
                SliderRow(label: "音量", value: $store.settings.voiceVolume, range: 0...1, step: 0.05) {
                    "\(Int($0 * 100))%"
                }
                SliderRow(label: "音调", value: $store.settings.voicePitch, range: 0.5...2, step: 0.1)
                Button("试听") {
                    Speaker.shared.configure(store.settings)
                    Speaker.shared.say("你好，我是 Myna，这是一段试听。")
                }
                .controlSize(.small)
            }

            SectionBox("语音输入") {
                SliderRow(label: "说完静音", value: $store.settings.silenceTimeout, range: 0.5...5, step: 0.1) {
                    String(format: "%.1f 秒后结束", $0)
                }
                SliderRow(label: "未说话放弃", value: $store.settings.noSpeechTimeout, range: 3...30, step: 1) {
                    "\(Int($0)) 秒"
                }
                Toggle("说完自动发送（不必按回车）", isOn: $store.settings.autoSendOnSilence)
                Toggle("再次按快捷键结束时直接发送", isOn: $store.settings.hotkeyAutoSend)
                Toggle("开始/结束录音时播放提示音", isOn: $store.settings.listenSound)
            }
        }
    }
}

// MARK: - 对话

private struct ChatTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("对话行为") {
                Toggle("连续对话（回答朗读完自动接着听）", isOn: $store.settings.continuousMode)
                Toggle("显示工具调用过程", isOn: $store.settings.showToolCalls)
                Toggle("自动滚动到最新消息", isOn: $store.settings.autoScroll)
                Toggle("关闭窗口时清空对话", isOn: $store.settings.clearOnClose)
            }
            SectionBox("输入") {
                Toggle("回车发送（关闭则用 ⌘回车发送）", isOn: $store.settings.sendOnEnter)
            }
            SectionBox("上下文") {
                HStack {
                    Text("保留最近对话轮数").font(.system(size: 12))
                    Spacer()
                    Stepper("\(store.settings.maxHistoryTurns)", value: $store.settings.maxHistoryTurns, in: 0...100, step: 2)
                        .labelsHidden()
                }
                Text("0 表示不限制。较小的值可减少 token 消耗与延迟。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 行为

/// 附加热键行：可录入 / 清除。
private struct ExtraHotKeyRow: View {
    let label: String
    @Binding var combo: String
    let slot: String
    @ObservedObject var hotKey = HotKeyManager.shared
    @State private var recording = false
    @State private var held: [String] = []

    private var heldPreview: String {
        var s = ""
        if held.contains("control") { s += "⌃" }
        if held.contains("option") { s += "⌥" }
        if held.contains("shift") { s += "⇧" }
        if held.contains("command") { s += "⌘" }
        return s
    }

    private var text: String {
        if recording { return heldPreview.isEmpty ? "请按下组合键…" : heldPreview }
        return combo.isEmpty ? "未设置" : HotKeyManager.display(combo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12)).frame(width: 84, alignment: .leading)
                Text(text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(combo.isEmpty && !recording ? .secondary : .primary)
                    .frame(minWidth: 88, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(recording ? Color.accentColor.opacity(0.15) : Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(recording ? Color.accentColor : Color.primary.opacity(0.12)))
                    .cornerRadius(7)
                Button(recording ? "取消" : "录入") { recording.toggle() }
                    .controlSize(.small)
                Button("清除") { combo = "" }
                    .controlSize(.small)
                    .disabled(combo.isEmpty || recording)
                Spacer()
                HotKeyRecorderField(
                    recording: recording,
                    onCapture: { c in
                        if HotKeyManager.isValid(c) { combo = c }
                        held = []
                        recording = false
                    },
                    onCancel: { held = []; recording = false },
                    onFlagsChanged: { held = $0 }
                )
                .frame(width: 1, height: 1)
            }
            if !hotKey.status(slot).isOK {
                Label(hotKey.status(slot).message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundColor(.orange)
                    .padding(.leading, 94)
            }
        }
    }
}

private struct BehaviorTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var hotKey = HotKeyManager.shared
    @State private var recording = false
    @State private var held: [String] = []

    private var heldPreview: String {
        var s = ""
        if held.contains("control") { s += "⌃" }
        if held.contains("option") { s += "⌥" }
        if held.contains("shift") { s += "⇧" }
        if held.contains("command") { s += "⌘" }
        return s
    }

    private var triggerKindBinding: Binding<String> {
        Binding(
            get: { HotKeyManager.isDoubleTap(store.settings.hotkey) ? "double" : "combo" },
            set: { kind in
                recording = false
                held = []
                store.settings.hotkey = kind == "double" ? "double:option" : "option+space"
            }
        )
    }

    private func openAccessibilitySettings() {
        HotKeyManager.promptAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private let icons = [
        "brain.head.profile", "sparkles", "bubble.left.and.bubble.right.fill",
        "waveform.circle.fill", "command.circle.fill", "bolt.circle.fill",
        "wand.and.stars", "cpu.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("快捷键") {
                HStack {
                    Text("触发方式").font(.system(size: 12)).frame(width: 60, alignment: .leading)
                    Picker("", selection: triggerKindBinding) {
                        Text("组合键").tag("combo")
                        Text("双击修饰键").tag("double")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if !HotKeyManager.isDoubleTap(store.settings.hotkey) {
                    HStack {
                        Text("按下行为").font(.system(size: 12)).frame(width: 60, alignment: .leading)
                        Picker("", selection: $store.settings.hotkeyMode) {
                            Text("按下切换").tag("toggle")
                            Text("按住说话").tag("pushToTalk")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if store.settings.hotkeyMode == "pushToTalk" {
                        Text("按住快捷键说话，松开即结束并发送。")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }

                if HotKeyManager.isDoubleTap(store.settings.hotkey) {
                    Picker("双击", selection: $store.settings.hotkey) {
                        ForEach(HotKeyManager.doubleTapModifiers, id: \.value) { m in
                            Text(m.label).tag(m.value)
                        }
                    }
                    Text("快速连按两次该修饰键触发（约 0.35 秒内）。需要辅助功能权限。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Text(recording
                             ? (heldPreview.isEmpty ? "请按下组合键…" : heldPreview)
                             : HotKeyManager.display(store.settings.hotkey))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(recording && heldPreview.isEmpty ? .secondary : .primary)
                            .frame(minWidth: 110, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(recording ? Color.accentColor.opacity(0.15) : Color(nsColor: .textBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(recording ? Color.accentColor : Color.primary.opacity(0.12)))
                            .cornerRadius(8)
                        Button(recording ? "取消" : "录入") { recording.toggle() }
                        Button("恢复默认") { store.settings.hotkey = "option+space" }
                            .disabled(recording)
                        Spacer()
                        HotKeyRecorderField(
                            recording: recording,
                            onCapture: { combo in
                                if HotKeyManager.isValid(combo) { store.settings.hotkey = combo }
                                held = []
                                recording = false
                            },
                            onCancel: { held = []; recording = false },
                            onFlagsChanged: { held = $0 }
                        )
                        .frame(width: 1, height: 1)
                    }
                    Text("点「录入」后按下想要的组合键（需带 ⌃⌥⇧⌘ 之一，或使用 F1–F12）。Esc 取消。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        ForEach(HotKeyManager.presets, id: \.value) { p in
                            Button(p.label) { store.settings.hotkey = p.value }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }

                if !hotKey.status.isOK {
                    HStack(spacing: 8) {
                        Label(hotKey.status.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundColor(.orange)
                        if hotKey.status == .needsAccessibility {
                            Button("打开系统设置") { openAccessibilitySettings() }
                                .controlSize(.small)
                        }
                    }
                }

                Divider().padding(.vertical, 2)
                Text("附加热键（可选）").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                ExtraHotKeyRow(label: "只打开窗口", combo: $store.settings.hotkeyOpen, slot: "open")
                ExtraHotKeyRow(label: "清空对话", combo: $store.settings.hotkeyClear, slot: "clear")
            }
            SectionBox("菜单栏图标") {
                HStack(spacing: 8) {
                    ForEach(icons, id: \.self) { name in
                        Button {
                            store.settings.menuBarIcon = name
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 15))
                                .frame(width: 30, height: 30)
                                .background(store.settings.menuBarIcon == name
                                            ? Color.accentColor.opacity(0.18)
                                            : Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            SectionBox("窗口与启动") {
                Toggle("窗口始终置顶", isOn: $store.settings.alwaysOnTop)
                Toggle("开机自动启动", isOn: $store.settings.launchAtLogin)
                Toggle("在 Dock 中显示图标", isOn: $store.settings.showInDock)
            }
            SectionBox("配置") {
                HStack {
                    Button("打开配置文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.path)])
                    }
                    Button("恢复默认设置") { store.reset() }
                }
                Text(store.path).font(.system(size: 10)).foregroundColor(.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - 工具

private struct ToolsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var query = ""

    private var items: [(name: String, desc: String)] {
        let all = ToolRunner.catalog()
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.name.lowercased().contains(q) || $0.desc.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关闭不想让模型调用的工具（其余全部启用）。危险工具建议保持关闭：shell_command、run_applescript。")
                .font(.system(size: 11)).foregroundColor(.secondary)

            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索工具", text: $query).textFieldStyle(.plain)
                Spacer()
                Button("全部启用") { store.settings.disabledTools = [] }.controlSize(.small)
                Button("全部停用") {
                    store.settings.disabledTools = ToolRunner.catalog().map(\.name)
                }.controlSize(.small)
            }

            List {
                ForEach(items, id: \.name) { item in
                    Toggle(isOn: binding(item.name)) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(item.name).font(.system(size: 12, weight: .medium))
                                if ["shell_command", "run_applescript"].contains(item.name) {
                                    Text("危险").font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.red.opacity(0.15))
                                        .foregroundColor(.red)
                                        .cornerRadius(4)
                                }
                            }
                            Text(item.desc).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 300)
        }
    }

    private func binding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !store.settings.disabledTools.contains(name) },
            set: { on in
                var d = store.settings.disabledTools
                if on { d.removeAll { $0 == name } }
                else if !d.contains(name) { d.append(name) }
                store.settings.disabledTools = d
            }
        )
    }
}

// MARK: - 关于

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile").font(.system(size: 44))
            Text("Myna").font(.title2).bold()
            Text("菜单栏语音助手，由大模型驱动，可操作 macOS").font(.system(size: 12)).foregroundColor(.secondary)
            Text("开源项目 · MIT License").font(.system(size: 11)).foregroundColor(.secondary)
            Divider().frame(width: 240)
            Text("快捷键 ⌥Space 唤起并开始聆听，再按一次结束").font(.system(size: 11)).foregroundColor(.secondary)
            Link("github.com/quyansiyuanwang/myna",
                 destination: URL(string: "https://github.com/quyansiyuanwang/myna")!)
                .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(20)
    }
}
