import SwiftUI
import AVFoundation
import AppKit

// MARK: - 分区

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, model, voice, chat, behavior, tools, market, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .model: return "模型"
        case .voice: return "语音"
        case .chat: return "对话"
        case .behavior: return "行为"
        case .tools: return "工具"
        case .market: return "市场"
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
        case .market: return "bag"
        case .about: return "info.circle"
        }
    }
}

/// 设置窗口的导航状态；供状态栏菜单「市场…」直接跳到市场分区。
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var section: SettingsSection? = .appearance
    private init() {}

    func open(_ section: SettingsSection) { self.section = section }
}

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var navigator = SettingsNavigator.shared

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $navigator.section) {
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
        switch navigator.section ?? .appearance {
        case .appearance: AppearanceTab(store: store)
        case .model: ModelTab(store: store)
        case .voice: VoiceTab(store: store)
        case .chat: ChatTab(store: store)
        case .behavior: BehaviorTab(store: store)
        case .tools: ToolsTab(store: store)
        case .market: MarketplaceTab()
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

// MARK: - 可输入的数字字段

/// 带文本框的数字输入（可直接键入，也可用步进器）。
private struct IntField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var width: CGFloat = 96
    var format: (Int) -> String = { "\($0)" }

    @State private var text = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12))
            Spacer()
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .onSubmit { commit() }
                .onChange(of: text) { _ in commitLive() }
                .onChange(of: value) { _ in if !editing { text = format(value) } }
                .onAppear { text = format(value) }
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .onChange(of: value) { _ in text = format(value) }
        }
    }

    private func commitLive() {
        editing = true
        defer { editing = false }
        if let v = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(v) {
            value = v
        }
    }

    private func commit() {
        if let v = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(v, range.lowerBound), range.upperBound)
        }
        text = format(value)
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    @State private var text = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12))
                Spacer()
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 78)
                    .onSubmit { commit() }
                    .onChange(of: text) { _ in commitLive() }
                    .onChange(of: value) { _ in if !editing { text = format(value) } }
                    .onAppear { text = format(value) }
            }
            if step > 0 {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }

    /// 去掉 “%”、“pt”、“秒” 等后缀后解析
    private func parse(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for suffix in ["%", "pt", "秒", "s", " tokens", "token"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return Double(s.trimmingCharacters(in: .whitespaces))
    }

    private func commitLive() {
        editing = true
        defer { editing = false }
        if let v = parse(text), range.contains(v) { value = v }
    }

    private func commit() {
        if let v = parse(text) {
            value = min(max(v, range.lowerBound), range.upperBound)
        }
        text = format(value)
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
    @State private var discovering = false
    @State private var showDiscovery = false
    @State private var discoveryQuery = ""
    @State private var discoveredModels: [String] = []
    @State private var discoveryError = ""

    private static let budgetPresets = [0, 1024, 4096, 8192, 16384, 32768]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            profilesSection

            SectionBox("接口") {
                Picker("接口类型", selection: $store.settings.api) {
                    ForEach(APIType.allCases) { t in
                        Text(t.label).tag(t.rawValue)
                    }
                }
                TextField("API 地址", text: $store.settings.baseURL).textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $store.settings.apiKey).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("模型", text: $store.settings.model).textFieldStyle(.roundedBorder)
                    discoverButton
                }
                HStack {
                    Button(testing ? "测试中…" : "测试连接") { test() }.disabled(testing)
                    Text(testResult).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                }
                Text("配置只描述接口协议；地址与模型由你填写，任何兼容端点都可用。")
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
                IntField(label: "最大 tokens", value: $store.settings.maxTokens, range: 256...131072, step: 256, width: 110)
                IntField(label: "失败重试次数", value: $store.settings.maxRetries, range: 0...6)
            }

            SectionBox("推理") {
                switch APIType.from(store.settings.api) {
                case .openAIResponses:
                    Picker("推理强度", selection: $store.settings.reasoningEffort) {
                        Text("关闭").tag("")
                        Text("minimal").tag("minimal")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                        Text("xhigh").tag("xhigh")
                        Text("max").tag("max")
                    }
                    Text("以 reasoning.effort 发送；选「关闭」则不发送该字段。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                case .anthropicMessages:
                    budgetStepper(label: "思考预算")
                    Text("以 thinking.budget_tokens 发送（0 = 关闭）。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                case .googleGenerativeAI:
                    budgetStepper(label: "thinkingConfig.thinkingBudget")
                    Text("以 generationConfig.thinkingConfig.thinkingBudget 发送（0 = 关闭）。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                case .openAICompletions:
                    Text("openai-completions 的推理由模型自身决定（选择带推理能力的模型即可），无需额外配置。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }

            SectionBox("高级") {
                IntField(label: "工具执行最大轮数", value: $store.settings.maxToolRounds, range: 0...64)
                Toggle("无限轮数", isOn: $store.settings.unlimitedToolRounds)
                    .font(.system(size: 12))
                Text("每次提问最多执行多少次工具调用；0 = 不限制，也可直接打开「无限轮数」。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                IntField(label: "保留最近对话轮数", value: $store.settings.maxHistoryTurns, range: 0...100, step: 2)
                Text("内置运行时的上下文裁剪；0 表示不限制。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            SectionBox("子agent") {
                IntField(label: "超时秒数", value: $store.settings.subagentTimeoutSeconds, range: 5...86_400, step: 30)
                IntField(label: "最大轮数", value: $store.settings.subagentMaxRounds, range: 1...200)
                IntField(label: "并行上限", value: $store.settings.subagentMaxParallel, range: 1...16)
                Text("run_subagent 使用独立上下文完成任务；run_subagents 并行运行多个子代理，并行上限限制同时运行的数量。子代理默认不能再派生子代理。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
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
        .onAppear {
            if let cached = ModelDiscoveryStore.shared.cached(baseURL: store.settings.baseURL,
                                                              api: store.settings.api) {
                discoveredModels = cached
            }
        }
    }

    // MARK: 模型列表

    private var profilesSection: some View {
        SectionBox("模型列表") {
            if store.settings.modelProfiles.isEmpty {
                Text("还没有保存的模型配置。填好下方接口信息后点「新建」即可保存。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(store.settings.modelProfiles) { p in
                        profileRow(p)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("新建（保存当前配置）") { store.addProfile(from: store.settings) }
                    .controlSize(.small)
                Button("更新当前") { store.updateProfile(from: store.settings) }
                    .controlSize(.small)
                    .disabled(store.settings.activeProfileID == nil)
            }
            Text("「应用」把该配置写入下方接口字段；修改接口字段不会自动改动已保存的配置。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func profileRow(_ p: ModelProfile) -> some View {
        let active = p.id == store.settings.activeProfileID
        return HStack(spacing: 8) {
            Image(systemName: active ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 11))
                .foregroundColor(active ? .accentColor : .secondary)
            TextField("名称", text: nameBinding(p.id))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110)
            Text(p.model.isEmpty ? "（未设置模型）" : p.model)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(p.api).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            Button("应用") { store.selectProfile(id: p.id) }
                .controlSize(.small).disabled(active)
            Button("复制") { store.duplicateProfile(id: p.id) }
                .controlSize(.small)
            Button("删除") { store.deleteProfile(id: p.id) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.settings.modelProfiles.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                guard let idx = store.settings.modelProfiles.firstIndex(where: { $0.id == id }) else { return }
                store.settings.modelProfiles[idx].name = newValue
            }
        )
    }

    // MARK: 模型探测

    private var discoverButton: some View {
        Button(discovering ? "探测中…" : "探测模型") { openOrDiscover() }
            .controlSize(.small)
            .disabled(discovering || store.settings.apiKey.isEmpty)
            .popover(isPresented: $showDiscovery, arrowEdge: .bottom) { discoveryList }
    }

    /// 有缓存就直接打开列表，否则发起探测。
    private func openOrDiscover() {
        let s = store.settings
        if let cached = ModelDiscoveryStore.shared.cached(baseURL: s.baseURL, api: s.api) {
            discoveredModels = cached
            discoveryError = ""
            showDiscovery = true
        } else {
            discover()
        }
    }

    private var discoveryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("搜索模型…", text: $discoveryQuery).textFieldStyle(.roundedBorder)
                Button {
                    discover()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(discovering)
                .help("重新探测")
            }
            if !discoveryError.isEmpty {
                Text(discoveryError).font(.system(size: 11)).foregroundColor(.red).lineLimit(3)
            }
            let filtered = discoveredModels.filter {
                discoveryQuery.isEmpty || $0.localizedCaseInsensitiveContains(discoveryQuery)
            }
            if filtered.isEmpty {
                Text(discoveredModels.isEmpty ? "没有可用的模型" : "没有匹配的模型")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered, id: \.self) { id in
                            Button {
                                store.settings.model = id
                                store.rememberRecent(id)
                                showDiscovery = false
                            } label: {
                                HStack(spacing: 6) {
                                    Text(id).font(.system(size: 12, design: .monospaced))
                                    Spacer()
                                    if id == store.settings.model {
                                        Image(systemName: "checkmark").font(.system(size: 10))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func discover() {
        discovering = true
        discoveryError = ""
        let s = store.settings
        Task {
            do {
                let ids = try await ModelDiscovery.discover(baseURL: s.baseURL, apiKey: s.apiKey, api: s.api)
                discoveredModels = ids
                ModelDiscoveryStore.shared.store(ids, baseURL: s.baseURL, api: s.api)
            } catch {
                discoveryError = error.localizedDescription
                if let cached = ModelDiscoveryStore.shared.cached(baseURL: s.baseURL, api: s.api) {
                    discoveredModels = cached
                }
            }
            discovering = false
            showDiscovery = true
        }
    }

    private func budgetStepper(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IntField(label: label,
                     value: $store.settings.thinkingBudget,
                     range: 0...32768,
                     step: 512,
                     width: 110,
                     format: { $0 == 0 ? "关闭" : "\($0)" })
            HStack(spacing: 6) {
                Text("预设").font(.system(size: 11)).foregroundColor(.secondary)
                ForEach(Self.budgetPresets, id: \.self) { value in
                    Button(value == 0 ? "关闭" : "\(value / 1024)k") {
                        store.settings.thinkingBudget = value
                    }
                    .controlSize(.small)
                }
            }
            Text("思考 budget 会在下一条消息生效（Agent 会按新配置重建）。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func test() {
        testing = true; testResult = ""
        let s = store.settings
        Task {
            do {
                let client = OpenAICompletionsClient(s)
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
                Toggle("自动滚动到最新消息", isOn: $store.settings.autoScroll)
                Toggle("关闭窗口时清空对话", isOn: $store.settings.clearOnClose)
            }
            SectionBox("显示内容") {
                Toggle("显示思考过程", isOn: $store.settings.showThinking)
                Toggle("显示工具调用", isOn: $store.settings.showToolCalls)
                Toggle("显示工具结果", isOn: $store.settings.showToolResults)
                Toggle("显示错误消息", isOn: $store.settings.showErrors)
                Toggle("思考区块默认收起", isOn: $store.settings.collapseThinking)
                    .disabled(!store.settings.showThinking)
                Toggle("工具区块默认收起", isOn: $store.settings.collapseTools)
                    .disabled(!store.settings.showToolCalls && !store.settings.showToolResults)
                Text("关闭显示会立即隐藏已有消息；顶栏的筛选按钮可按关键词过滤消息。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            SectionBox("输入") {
                Toggle("回车发送（关闭则用 ⌘回车发送）", isOn: $store.settings.sendOnEnter)
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
                    // 自定义图案（应用图标中央的丝带 m）
                    Button {
                        store.settings.menuBarIcon = "custom"
                    } label: {
                        Group {
                            if let img = NSImage(named: "MenuBarTemplate") {
                                Image(nsImage: img)
                                    .renderingMode(.template)
                                    .resizable().scaledToFit()
                                    .frame(width: 20, height: 15)
                            } else {
                                Image(systemName: "brain.head.profile").font(.system(size: 15))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .background(store.settings.menuBarIcon == "custom"
                                    ? Color.accentColor.opacity(0.18)
                                    : Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .help("自定义图案（丝带 m）")

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
                        .help(name)
                    }
                }
                SliderRow(label: "图标大小", value: $store.settings.menuBarIconSize, range: 11...22, step: 1) {
                    "\(Int($0)) pt"
                }
            }
            SectionBox("窗口与启动") {
                Toggle("下拉面板模式（贴顶展开、失焦自动关闭）", isOn: $store.settings.panelMode)
                Toggle("允许拖拽调整面板大小", isOn: $store.settings.resizablePanel)
                    .disabled(!store.settings.panelMode)
                Toggle("窗口始终置顶", isOn: $store.settings.alwaysOnTop)
                    .disabled(store.settings.panelMode)
                Toggle("开机自动启动", isOn: $store.settings.launchAtLogin)
                Toggle("在 Dock 中显示图标", isOn: $store.settings.showInDock)
                Text("切换面板/窗口模式后重新打开生效。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
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
                TextField("搜索工具", text: $query).textFieldStyle(.roundedBorder)
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

// MARK: - 市场

/// 社区市场：从 myna-hub 仓库安装技能、MCP 与插件。
private struct MarketplaceTab: View {
    @ObservedObject var market = Marketplace.shared
    @State private var query = ""

    private func matches(_ fields: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return fields.contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("社区仓库") {
                HStack(spacing: 8) {
                    Button {
                        Task { await market.refresh() }
                    } label: {
                        Label(market.isLoading ? "刷新中…" : "刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(market.isLoading)
                    if let updated = market.lastUpdated {
                        Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索技能、MCP 或插件", text: $query).textFieldStyle(.roundedBorder)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(7)

                Text("来源：github.com/quyansiyuanwang/myna-hub")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                if let error = market.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            skillsSection
            mcpsSection
            pluginsSection
        }
        .task {
            if market.skills.isEmpty && market.mcps.isEmpty && market.plugins.isEmpty {
                await market.refresh()
            }
        }
    }

    // MARK: 技能

    private var skillsSection: some View {
        SectionBox("技能") {
            let items = market.skills.filter { matches([$0.id, $0.name, $0.description] + $0.tags) }
            if market.skills.isEmpty {
                hint("尚未加载技能。点上方「刷新」从社区仓库获取。")
            } else if items.isEmpty {
                hint("没有匹配「\(query)」的技能。")
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { skill in
                        row(name: skill.name, id: skill.id, description: skill.description,
                            author: skill.author, tags: skill.tags,
                            detail: nil, key: Marketplace.key("skill", skill.id),
                            install: { Task { await market.install(skill: skill) } },
                            uninstall: { Task { await market.uninstall(skill: skill) } })
                    }
                }
            }
        }
    }

    // MARK: MCP

    private var mcpsSection: some View {
        SectionBox("MCP") {
            let items = market.mcps.filter { matches([$0.id, $0.name, $0.description] + $0.tags) }
            if market.mcps.isEmpty {
                hint("尚未加载 MCP 服务器。点上方「刷新」从社区仓库获取。")
            } else if items.isEmpty {
                hint("没有匹配「\(query)」的 MCP。")
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { mcp in
                        row(name: mcp.name, id: mcp.id, description: mcp.description,
                            author: mcp.author, tags: mcp.tags,
                            detail: nil, key: Marketplace.key("mcp", mcp.id),
                            install: { Task { await market.install(mcp: mcp) } },
                            uninstall: { Task { await market.uninstall(mcp: mcp) } })
                    }
                }
            }
        }
    }

    // MARK: 插件

    private var pluginsSection: some View {
        SectionBox("插件") {
            let items = market.plugins.filter { matches([$0.id, $0.name, $0.description] + $0.tags) }
            if market.plugins.isEmpty {
                hint("尚未加载插件。点上方「刷新」从社区仓库获取。")
            } else if items.isEmpty {
                hint("没有匹配「\(query)」的插件。")
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { plugin in
                        let installs = plugin.skills.map { "技能 \($0)" } + plugin.mcps.map { "MCP \($0)" }
                        row(name: plugin.name, id: plugin.id, description: plugin.description,
                            author: plugin.author, tags: plugin.tags,
                            detail: installs.isEmpty ? nil : "将安装：" + installs.joined(separator: "、"),
                            key: Marketplace.key("plugin", plugin.id),
                            install: { Task { await market.install(plugin: plugin) } },
                            uninstall: { Task { await market.uninstall(plugin: plugin) } })
                    }
                }
            }
        }
    }

    // MARK: 通用行

    private func row(name: String, id: String, description: String, author: String,
                     tags: [String], detail: String?, key: String,
                     install: @escaping () -> Void, uninstall: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    Text(id).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if !author.isEmpty { chip("作者 \(author)") }
                    ForEach(tags, id: \.self) { chip("#\($0)") }
                }
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            MarketActionButton(state: market.state(key: key), install: install, uninstall: uninstall)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12))
            .foregroundColor(.secondary)
            .cornerRadius(4)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 安装 / 卸载按钮，按状态显示进度与结果。
private struct MarketActionButton: View {
    let state: InstallState
    let install: () -> Void
    let uninstall: () -> Void

    var body: some View {
        switch state {
        case .idle:
            Button("安装", action: install).controlSize(.small)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("安装中…").font(.system(size: 11)).foregroundColor(.secondary)
            }
        case .installed:
            VStack(alignment: .trailing, spacing: 4) {
                Label("已安装", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundColor(.green)
                Button("卸载", action: uninstall).controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 3) {
                Button("重试", action: install).controlSize(.small)
                Text(message)
                    .font(.system(size: 9)).foregroundColor(.red)
                    .lineLimit(3)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        }
    }
}
