import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - 分区

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, model, profiles, voice, chat, behavior, tools, market, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .model: return "模型"
        case .profiles: return "配置"
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
        case .profiles: return "square.stack.3d.up"
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
        case .profiles: ProfilesTab(store: store)
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

/// 供应商 → 模型 的整合树。
///
/// 供应商行即「当前供应商」，点行体切换；展开后内联编辑供应商字段与该供应商的模型。
/// 选中模型会写入扁平字段（地址与 Key 取所属供应商），因此下游运行时无需改动。
private struct ModelTab: View {
    @ObservedObject var store: SettingsStore
    @State private var testResult = ""
    @State private var testing = false
    @State private var discovering = false
    @State private var newModelName = ""
    @State private var editingModelID: UUID?
    @State private var editingProviderID: UUID?
    @State private var expandedProviderID: UUID?
    @State private var message = ""

    private static let budgetPresets = [0, 1024, 4096, 8192, 16384, 32768]

    /// 顶栏显示的当前选择。
    private var currentSelectionLabel: String {
        guard let pid = store.currentProviderID,
              let provider = store.settings.providers.first(where: { $0.id == pid }) else { return "未选择" }
        let name = provider.name.isEmpty ? "未命名" : provider.name
        if let entry = store.currentModelEntry { return "\(name) / \(entry.label)" }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            providersModelsSection
                .onAppear {
                    if expandedProviderID == nil {
                        expandedProviderID = store.currentProviderID ?? store.settings.providers.first?.id
                    }
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
                Text("这里是全局默认值；单个模型可在「供应商与模型 → 编辑」中覆盖温度与最大 tokens。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            SectionBox("推理") {
                Text("作用于当前模型「\(store.currentModelLabel)」")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                switch APIType.from(store.settings.api) {
                case .openAIResponses:
                    Picker("推理强度", selection: reasoningEffortBinding) {
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
    }

    // MARK: 供应商与模型

    /// 整合树：供应商行即当前供应商，展开后内联编辑字段、模型与模型编辑器。
    private var providersModelsSection: some View {
        SectionBox("供应商与模型") {
            Text("当前：\(currentSelectionLabel)")
                .font(.system(size: 11)).foregroundColor(.secondary)

            if store.settings.providers.isEmpty {
                Text("还没有供应商。点下方「新建」添加。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.settings.providers) { p in providerNode(p) }
                }
            }

            HStack(spacing: 6) {
                Button("新建") {
                    let p = store.addProvider()
                    expandedProviderID = p.id
                    editingProviderID = p.id
                    message = "已新建「\(p.name)」，请填写地址与 Key"
                }
                .controlSize(.small)
                Text(message.isEmpty ? "" : message)
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
        }
    }

    /// 一个供应商节点：容器头 + 展开内容（字段编辑器、模型子列表与模型编辑器）。
    @ViewBuilder
    private func providerNode(_ p: Provider) -> some View {
        let active = p.id == store.currentProviderID
        let expanded = p.id == expandedProviderID

        // 整个供应商是一个容器：头部是容器标题，模型是缩进的子级。
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // 箭头只负责展开 / 收起，是独立的点击区。
                Button {
                    expandedProviderID = expanded ? nil : p.id
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 行体是容器标题，切换当前供应商。
                Button {
                    store.selectProvider(id: p.id)
                    expandedProviderID = p.id
                    editingModelID = nil
                    message = "已切换到供应商「\(p.name)」"
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 12))
                            .foregroundColor(active ? .accentColor : .secondary)
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundColor(active ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(p.name.isEmpty ? "未命名" : p.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if active {
                                    Text("当前")
                                        .font(.system(size: 8))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.16))
                                        .cornerRadius(3)
                                }
                            }
                            Text("\(APIType.from(p.api).label) · \(p.models.count) 个模型")
                                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                            Text(p.baseURL.isEmpty ? "未设置地址" : p.baseURL)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(editingProviderID == p.id ? "收起" : "编辑") {
                    if editingProviderID == p.id {
                        editingProviderID = nil
                    } else {
                        editingProviderID = p.id
                        expandedProviderID = p.id
                    }
                }
                .controlSize(.small)
                Button("复制") {
                    if let copy = store.duplicateProvider(id: p.id) {
                        expandedProviderID = copy.id
                        message = "已复制为「\(copy.name)」"
                    }
                }
                .controlSize(.small)
                Button("删除") {
                    let name = p.name
                    store.deleteProvider(id: p.id)
                    if expandedProviderID == p.id { expandedProviderID = nil }
                    if editingProviderID == p.id { editingProviderID = nil }
                    message = "已删除「\(name)」"
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Color.accentColor.opacity(0.14) : Color.clear)
            .contextMenu {
                Button(editingProviderID == p.id ? "收起编辑" : "编辑") {
                    if editingProviderID == p.id {
                        editingProviderID = nil
                    } else {
                        editingProviderID = p.id
                        expandedProviderID = p.id
                    }
                }
                Button("复制") {
                    if let copy = store.duplicateProvider(id: p.id) {
                        expandedProviderID = copy.id
                        message = "已复制为「\(copy.name)」"
                    }
                }
                Button("测试连接") { test(providerID: p.id) }
                    .disabled(testing || p.models.isEmpty)
                Button("探测并添加") {
                    expandedProviderID = p.id
                    discover(providerID: p.id)
                }
                Divider()
                Button("删除", role: .destructive) {
                    let name = p.name
                    store.deleteProvider(id: p.id)
                    if expandedProviderID == p.id { expandedProviderID = nil }
                    if editingProviderID == p.id { editingProviderID = nil }
                    message = "已删除「\(name)」"
                }
            }

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if editingProviderID == p.id {
                        providerEditor(p.id)
                            .padding(.horizontal, 8)
                    }

                    // 模型列表是缩进的子级：左侧 1pt 导轨 + 显式「模型」标题。
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("模型（\(p.models.count)）")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            if p.models.isEmpty {
                                Text("「\(p.name)」还没有模型。可在下方手动输入模型 id，或点「探测并添加」从端点拉取。")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            } else {
                                ForEach(p.models) { m in modelRow(m, providerID: p.id) }
                            }
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 6)

                    HStack(spacing: 8) {
                        TextField("手动输入模型 id", text: $newModelName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addManualModel(to: p.id) }
                        Button("添加") { addManualModel(to: p.id) }
                            .controlSize(.small)
                            .disabled(newModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(discovering ? "探测中…" : "探测并添加") { discover(providerID: p.id) }
                            .controlSize(.small)
                            .disabled(discovering || p.apiKey.isEmpty)
                    }
                    .padding(.leading, 27)
                    .padding(.trailing, 8)

                    if let mid = editingModelID, p.models.contains(where: { $0.id == mid }) {
                        modelEditor(providerID: p.id, modelID: mid)
                            .padding(.leading, 27)
                            .padding(.trailing, 8)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .leading) {
            if active {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func providerEditor(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("供应商名称", text: providerString(id, \.name))
                .textFieldStyle(.roundedBorder)
            Picker("接口类型", selection: providerString(id, \.api)) {
                ForEach(APIType.allCases) { t in Text(t.label).tag(t.rawValue) }
            }
            TextField("API 地址", text: providerString(id, \.baseURL))
                .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: providerString(id, \.apiKey))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button(testing ? "测试中…" : "测试连接") { test(providerID: id) }
                    .controlSize(.small)
                    .disabled(testing || provider(id)?.models.isEmpty == true)
                Text(testResult).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
            Text(provider(id)?.models.first.map { "测试使用该供应商的第一个模型：\($0.name)" }
                 ?? "该供应商还没有模型，先添加一个模型才能测试。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// 模型行：子级视觉——无填充无边框，靠缩进导轨、cube 图标与等宽字体区分于供应商头。
    private func modelRow(_ m: ModelEntry, providerID pid: UUID) -> some View {
        let active = m.id == store.currentModelID
        return HStack(spacing: 6) {
            Button {
                store.selectModel(providerID: pid, modelID: m.id)
                editingModelID = nil
                message = "已切换到「\(m.name)」"
            } label: {
                HStack(spacing: 6) {
                    // 活动模型用细强调色竖条标记，绝不做整行填充。
                    Rectangle()
                        .fill(active ? Color.accentColor : Color.clear)
                        .frame(width: 2)
                    Image(systemName: "cube")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(m.name)
                                .font(.system(size: 12, weight: active ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(active ? .accentColor : .primary)
                                .lineLimit(1)
                            if m.discovered {
                                Text("探测")
                                    .font(.system(size: 8))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.14))
                                    .cornerRadius(3)
                            }
                        }
                        if !m.displayName.isEmpty && m.displayName != m.name {
                            Text(m.displayName).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Text(modelSubtitle(m))
                            .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(minHeight: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(editingModelID == m.id ? "收起" : "编辑") {
                editingModelID = editingModelID == m.id ? nil : m.id
            }
            .controlSize(.small)
            Button("复制") { store.duplicateModel(id: m.id, inProvider: pid) }
                .controlSize(.small)
            Button("删除") {
                store.deleteModel(id: m.id, inProvider: pid)
                if editingModelID == m.id { editingModelID = nil }
            }
            .controlSize(.small)
        }
    }

    private func modelSubtitle(_ m: ModelEntry) -> String {
        var parts: [String] = []
        if !m.reasoningSummary.isEmpty { parts.append(m.reasoningSummary) }
        if m.maxTokens > 0 { parts.append("max \(m.maxTokens)") }
        if m.temperature >= 0 { parts.append(String(format: "温度 %.2f", m.temperature)) }
        if m.contextWindow > 0 { parts.append("上下文 \(m.contextWindow)") }
        return parts.isEmpty ? "沿用全局参数" : parts.joined(separator: " · ")
    }

    /// 模型编辑器：显示名、采样覆盖、上下文窗口。
    private func modelEditor(providerID pid: UUID, modelID mid: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            TextField("显示名（留空则显示模型 id）", text: modelValue(pid, mid, \.displayName, ""))
                .textFieldStyle(.roundedBorder)
            IntField(label: "最大 tokens（0 = 全局）",
                     value: modelValue(pid, mid, \.maxTokens, 0),
                     range: 0...131072,
                     step: 256,
                     width: 100,
                     format: { $0 == 0 ? "全局" : "\($0)" })
            SliderRow(label: "温度（-1 = 全局）",
                      value: modelValue(pid, mid, \.temperature, -1),
                      range: -1...1.5,
                      step: 0.05) {
                $0 < 0 ? "全局" : String(format: "%.2f", $0)
            }
            IntField(label: "上下文窗口（0 = 未知）",
                     value: modelValue(pid, mid, \.contextWindow, 0),
                     range: 0...2_000_000,
                     step: 1024,
                     width: 110,
                     format: { $0 == 0 ? "未知" : "\($0)" })
            Text("推理参数（推理强度 / 思考预算）在下方「推理」分区设置，作用于当前模型。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: 绑定

    private func provider(_ id: UUID) -> Provider? {
        store.settings.providers.first(where: { $0.id == id })
    }

    private func providerString(_ id: UUID, _ keyPath: WritableKeyPath<Provider, String>) -> Binding<String> {
        Binding(
            get: { provider(id)?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let i = store.settings.providers.firstIndex(where: { $0.id == id }) else { return }
                store.settings.providers[i][keyPath: keyPath] = value
                // 编辑的是当前供应商时，同步到扁平字段，保证正在生效的配置跟着变。
                if store.settings.activeProviderID == id { store.applyActiveSelection() }
            }
        )
    }

    private func modelValue<T>(
        _ pid: UUID,
        _ mid: UUID,
        _ keyPath: WritableKeyPath<ModelEntry, T>,
        _ fallback: T
    ) -> Binding<T> {
        Binding(
            get: {
                store.settings.providers.first(where: { $0.id == pid })?
                    .models.first(where: { $0.id == mid })?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                guard let pi = store.settings.providers.firstIndex(where: { $0.id == pid }),
                      let mi = store.settings.providers[pi].models.firstIndex(where: { $0.id == mid })
                else { return }
                store.settings.providers[pi].models[mi][keyPath: keyPath] = value
                store.syncCurrentModel(providerID: pid, modelID: mid)
            }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(get: { store.settings.reasoningEffort },
                set: { store.updateCurrentReasoning(effort: $0) })
    }

    private var thinkingBudgetBinding: Binding<Int> {
        Binding(get: { store.settings.thinkingBudget },
                set: { store.updateCurrentReasoning(budget: $0) })
    }

    // MARK: 动作

    private func addManualModel(to pid: UUID) {
        guard let provider = provider(pid) else { return }
        let name = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if provider.models.contains(where: { $0.name == name }) {
            message = "「\(name)」已在列表中"
            return
        }
        store.addModel(named: name, toProvider: pid)
        newModelName = ""
        message = "已添加模型「\(name)」"
    }

    private func discover(providerID pid: UUID) {
        guard let provider = provider(pid) else { return }
        discovering = true
        message = "正在探测「\(provider.name)」的模型…"
        Task {
            do {
                let ids = try await ModelDiscovery.discover(baseURL: provider.baseURL,
                                                            apiKey: provider.apiKey,
                                                            api: provider.api)
                let added = store.mergeDiscoveredModels(ids, intoProvider: pid)
                ModelDiscoveryStore.shared.store(ids, baseURL: provider.baseURL, api: provider.api)
                message = "探测到 \(ids.count) 个模型，新增 \(added) 个"
                // 探测不会自动切换当前模型；如需使用，点该行的「应用」。
            } catch {
                message = error.localizedDescription
            }
            discovering = false
        }
    }

    private func test(providerID id: UUID?) {
        var probe = store.settings
        if let id, let provider = provider(id) {
            probe.api = provider.api
            probe.baseURL = provider.baseURL
            probe.apiKey = provider.apiKey
            if let first = provider.models.first { probe.model = first.name }
        }
        testing = true
        testResult = ""
        Task {
            do {
                let client = OpenAICompletionsClient(probe)
                let msg = try await client.chat(messages: [["role": "user", "content": "ping，只回复 pong"]], tools: [])
                let text = (msg["content"] as? String) ?? "(空)"
                testResult = "✅ 连接成功：\(text.prefix(30))"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func budgetStepper(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IntField(label: label,
                     value: thinkingBudgetBinding,
                     range: 0...32768,
                     step: 512,
                     width: 110,
                     format: { $0 == 0 ? "关闭" : "\($0)" })
            HStack(spacing: 6) {
                Text("预设").font(.system(size: 11)).foregroundColor(.secondary)
                ForEach(Self.budgetPresets, id: \.self) { value in
                    Button(value == 0 ? "关闭" : "\(value / 1024)k") {
                        thinkingBudgetBinding.wrappedValue = value
                    }
                    .controlSize(.small)
                }
            }
            Text("思考 budget 会在下一条消息生效（Agent 会按新配置重建）。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}

// MARK: - 配置方案

/// 配置方案：保存**全部设置**的快照（不只是模型）。
///
/// 每个方案是 `~/.config/myna/profiles/<name>.json` 里的一份完整配置，
/// 与 `config.json` 同构，因此切换方案会一并恢复外观、语音、对话、行为等设置。
private struct ProfilesTab: View {
    @ObservedObject var store: SettingsStore
    @State private var profiles: [String] = []
    @State private var newName = ""
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("配置方案") {
                if profiles.isEmpty {
                    Text("还没有配置方案。调整好设置后，在下方输入名称并点「保存当前为新方案」。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(profiles, id: \.self) { name in profileRow(name) }
                    }
                }

                HStack(spacing: 8) {
                    TextField("方案名称", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button("保存当前为新方案") { save() }
                        .controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack(spacing: 8) {
                    Button("导入方案…") { importProfile() }.controlSize(.small)
                    Spacer()
                }

                Text("方案包含全部设置（供应商与模型、外观、语音、对话、行为、工具、系统提示词等），点「应用」即可整体切换。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(SettingsStore.profilesDirectory)
                    .font(.system(size: 10)).foregroundColor(.secondary).textSelection(.enabled)
                if !message.isEmpty {
                    Text(message).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                }
            }

            SectionBox("完整配置") {
                HStack(spacing: 8) {
                    Button("打开配置文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.path)])
                    }
                    Button("恢复默认设置") { store.reset(); reload() }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("导出当前完整配置…") { exportConfig() }
                    Button("导入完整配置…") { importConfig() }
                    Spacer()
                }
                Text("导出内容包含 API Key，请妥善保管；导入完整配置会整体替换当前设置（旧的模型档案会自动迁移）。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(store.path)
                    .font(.system(size: 10)).foregroundColor(.secondary).textSelection(.enabled)
            }
        }
        .onAppear { reload() }
    }

    // MARK: 行

    private func profileRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 11)).foregroundColor(.secondary)
            if renameTarget == name {
                TextField("名称", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 180)
                    .onSubmit { commitRename() }
                Button("确定") { commitRename() }.controlSize(.small)
                Button("取消") { renameTarget = nil }.controlSize(.small)
                Spacer()
            } else {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button("应用") { apply(name) }.controlSize(.small)
                Button("重命名") { renameTarget = name; renameText = name }.controlSize(.small)
                Button("导出…") { export(name) }.controlSize(.small)
                Button("删除") {
                    store.deleteProfile(named: name)
                    reload()
                    message = "已删除「\(name)」"
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 动作

    private func reload() {
        profiles = store.listProfiles()
        if let target = renameTarget, !profiles.contains(target) { renameTarget = nil }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existed = store.listProfiles().contains(name)
        if store.saveProfile(named: name) {
            message = existed ? "已覆盖方案「\(name)」" : "已保存方案「\(name)」"
            newName = ""
            reload()
        } else {
            message = "保存失败，请检查方案名称"
        }
    }

    private func apply(_ name: String) {
        if store.applyProfile(named: name) {
            message = "已应用方案「\(name)」"
        } else {
            message = "读取方案「\(name)」失败"
        }
    }

    private func commitRename() {
        guard let old = renameTarget else { return }
        let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !new.isEmpty, new != old else { return }
        if store.renameProfile(from: old, to: new) {
            message = "已重命名为「\(new)」"
        } else {
            message = "重命名失败（名称重复或文件不存在）"
        }
        reload()
    }

    private func export(_ name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "myna-\(name).json"
        panel.message = "导出的方案包含 API Key，请妥善保管"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = store.exportProfile(named: name, to: url)
            ? "已导出到 \(url.lastPathComponent)"
            : "导出失败"
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        message = store.importProfile(from: url, as: name)
            ? "已导入方案「\(name)」"
            : "文件格式不正确"
        reload()
    }

    private func exportConfig() {
        guard let data = store.exportSettings() else { message = "导出失败"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "myna-config.json"
        panel.message = "导出内容包含 API Key，请妥善保管"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            message = "已导出到 \(url.lastPathComponent)"
        } catch {
            message = "写入失败：\(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        message = store.importSettings(from: data) ? "已导入 \(url.lastPathComponent)" : "文件格式不正确"
        reload()
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
            SectionBox("运行") {
                Toggle("切换会话时后台继续运行", isOn: $store.settings.backgroundRuns)
                IntField(label: "并行运行上限",
                         value: $store.settings.maxParallelRuns,
                         range: 1...16)
                    .disabled(!store.settings.backgroundRuns)
                Text("开启后，切换会话或关闭面板不会打断正在进行的回答；多个会话可同时运行，超出上限时会自动停止最旧的会话。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
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
                HStack(spacing: 8) {
                    Button("配置方案…") { SettingsNavigator.shared.open(.profiles) }
                    Spacer()
                }
                Text("完整配置的保存、切换与导入导出已移到「配置」分区。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 16) {
            SectionBox("编程") {
                Toggle("编码模式", isOn: $store.settings.codingMode)
                    .font(.system(size: 12))
                Text("开启后向系统提示词追加编码专用说明（资深工程师角色、先查看再修改、改动后验证、总结变更）。")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                if store.settings.codingMode, !store.settings.unlimitedToolRounds, store.settings.maxToolRounds < 32 {
                    Text("提示：编码任务往往需要多轮工具调用，建议在「模型 → 高级」中开启「无限工具轮数」或提高「工具执行最大轮数」。")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }

                HStack(spacing: 6) {
                    Text("工作目录").font(.system(size: 12))
                    Spacer()
                    TextField("默认用户主目录", text: $store.settings.workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 260)
                    Button("选择…") { chooseDirectory() }.controlSize(.small)
                }
                Text("文件 / Git 工具的默认相对路径基准；留空则使用用户主目录。")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                IntField(label: "单文件读取上限（字节）", value: $store.settings.maxReadBytes,
                         range: 1_024...104_857_600, step: 1_024, width: 120)
                IntField(label: "命令超时（秒）", value: $store.settings.commandTimeoutSeconds,
                         range: 1...3_600, step: 10)
                IntField(label: "输出最大字符数", value: $store.settings.maxOutputChars,
                         range: 1_000...1_000_000, step: 1_000, width: 120)

                Toggle("危险工具需用户确认", isOn: $store.settings.confirmDangerousTools)
                    .font(.system(size: 12))
                Text("开启后，delete_path / git_commit / run_command / shell_command / run_applescript 会直接拒绝执行，要求模型先向用户说明并取得确认；确认后需关闭本开关才能继续。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Text("关闭不想让模型调用的工具（其余全部启用）。危险工具建议保持关闭：\(ToolRunner.dangerousTools.sorted().joined(separator: "、"))。")
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
                                if ToolRunner.dangerousTools.contains(item.name) {
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
            .frame(minHeight: 260)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择文件工具的默认工作目录"
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.workingDirectory = url.path
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
