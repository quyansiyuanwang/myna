import SwiftUI

enum GuidePage: String, CaseIterable { case safety = "安全守护", catalog = "能力清单" }

struct GuideStrip: View {
    @ObservedObject var activity: GuardActivity
    let open: (GuidePage) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { open(.safety) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(Color.accentColor)
                    Text("安全守护").fontWeight(.medium)
                    Text("本次已拦截 \(activity.count) 次").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .help("查看危险操作拦截记录与本地演示")
            Spacer(minLength: 4)
            Button { open(.catalog) } label: { Label("能力清单", systemImage: "list.bullet.rectangle") }
        }
        .font(.caption).buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}

struct ToolGuideView: View {
    let page: GuidePage
    let mode: ChatMode
    @ObservedObject var activity: GuardActivity
    let select: (GuidePage) -> Void
    let back: () -> Void
    let permissions: () -> Void
    @State private var catalogQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("返回聊天", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Picker("页面", selection: Binding(get: { page }, set: select)) {
                    ForEach(GuidePage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(12)
            Divider()
            switch page {
            case .safety:
                SafetyOverview(activity: activity, permissions: permissions) { tool in
                    catalogQuery = tool
                    select(.catalog)
                }
            case .catalog: CapabilityCatalog(mode: mode, query: $catalogQuery)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SafetyOverview: View {
    @ObservedObject var activity: GuardActivity
    let permissions: () -> Void
    let showTool: (String) -> Void
    @ObservedObject private var demo = GuardDemo.Session.shared

    private var runTitle: String {
        switch demo.state {
        case .idle: return "运行拦截演示"
        case .running: return "正在验证…"
        case .verified, .failed: return "重新验证"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("安全守护", systemImage: "shield.lefthalf.filled").font(.title2.bold())
                    Spacer()
                    Button("管理工具权限…", action: permissions).controlSize(.small)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(activity.count)").font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    Text("次危险操作被拦截").font(.headline)
                }
                Text("本次启动以来 · 所有会话 · 不含演示").font(.caption).foregroundStyle(.secondary)
                if let last = activity.latest {
                    LabeledContent("最近拦截") { Text(last.date, style: .time) }
                    Text(last.tool).font(.body.monospaced())
                    Text(last.reason.rawValue).foregroundStyle(.secondary)
                } else {
                    Text("暂无真实拦截记录").foregroundStyle(.secondary)
                }
                Divider()
                Label("删除文件演示", systemImage: "trash").font(.headline)
                Text("模拟一次删除请求，检验计划模式的只读限制。仅使用临时样本，无需连接模型。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("工具") { Text(GuardDemo.toolName).font(.body.monospaced()) }
                LabeledContent("临时样本", value: GuardDemo.filename)
                HStack(spacing: 12) {
                    Button { Task { await demo.verify() } } label: { Label(runTitle, systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).disabled(demo.isRunning)
                    Button("查看工具策略") { showTool(GuardDemo.toolName) }.buttonStyle(.link)
                }
                switch demo.state {
                case .verified(let receipt):
                    DemoReceiptView(receipt: receipt).id(receipt.block.date)
                case .failed(let message):
                    Label("验证未完成：\(message)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                case .running, .idle: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

}

private struct DemoReceiptView: View {
    let receipt: GuardDemo.Receipt
    @State private var copyStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("演示请求已拦截", systemImage: "checkmark.shield.fill").font(.headline)
            Text(receipt.block.reason.rawValue)
            Text("已读回样本并核对内容：文件未被删除或修改。")
            HStack {
                Text(receipt.block.date, style: .time).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    copyStatus = pb.setString(receipt.summary, forType: .string) ? "已复制摘要" : "复制失败，重试"
                } label: {
                    Label(copyStatus ?? "复制验证摘要", systemImage: "doc.on.doc")
                }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum CapabilityGroup: String, CaseIterable {
    case files = "文件与开发", screen = "屏幕与输入", web = "网络与检索", system = "Mac 与日常事务"
    case agents = "任务与子代理", resources = "配置与扩展", mcp = "MCP 工具"

    var label: (icon: String, example: String) {
        switch self {
        case .files: return ("folder", "查找项目文件、查看 Git 改动")
        case .screen: return ("macwindow", "识别屏幕文字、操作窗口")
        case .web: return ("globe", "搜索资料、读取网页正文")
        case .system: return ("calendar", "打开应用、添加提醒与日程")
        case .agents: return ("person.2", "分派子任务、报告目标进度")
        case .resources: return ("slider.horizontal.3", "管理技能、插件与本地配置")
        case .mcp: return ("puzzlepiece.extension", "当前已连接服务提供的工具")
        }
    }

    static func group(for name: String) -> Self {
        if name.hasPrefix("mcp__") { return .mcp }
        if ToolRunner.codingToolNames.contains(name) || ["shell_command", "run_applescript"].contains(name) { return .files }
        if ComputerUse.allTools.contains(name) { return .screen }
        if ["web_search", "fetch_url", "open_url"].contains(name) { return .web }
        if ToolRunner.subAgentExcluded.contains(name) || name == "goal_report" { return .agents }
        if SelfControlAPI.toolNames.contains(name) || ["list_skills", "read_skill"].contains(name) { return .resources }
        return .system
    }
}

private struct CapabilityCatalog: View {
    let mode: ChatMode
    @Binding var query: String
    @ObservedObject private var store = SettingsStore.shared
    @State private var catalog: [(name: String, desc: String)] = []
    @State private var expanded: Set<CapabilityGroup> = []

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = catalog.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)
            || $0.desc.localizedCaseInsensitiveContains(term) || CapabilityGroup.group(for: $0.name).rawValue.contains(term) }
        let groups = Dictionary(grouping: matches) { CapabilityGroup.group(for: $0.name) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("能力清单").font(.title2.bold())
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("刷新工具清单").help("刷新工具清单")
            }
            Text("已注册 \(catalog.count) 项工具 · 当前策略：\(mode.title)模式")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("搜索工具名称、用途或分类", text: $query).textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).accessibilityLabel("清除搜索").help("清除搜索")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("未找到匹配的工具").foregroundStyle(.secondary).padding(.vertical)
                    }
                    ForEach(CapabilityGroup.allCases, id: \.self) { group in
                        if let tools = groups[group] {
                            let open = !term.isEmpty || expanded.contains(group)
                            Button {
                                if open { expanded.remove(group) } else { expanded.insert(group) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: group.label.icon).foregroundStyle(Color.accentColor).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.rawValue).font(.headline)
                                        Text(group.label.example).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(tools.count)").monospacedDigit().foregroundStyle(.secondary)
                                    if term.isEmpty { Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption) }
                                }.padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!term.isEmpty)
                            if open {
                                ForEach(tools, id: \.name) { tool in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(tool.name).font(.callout.monospaced()).textSelection(.enabled)
                                            Spacer(minLength: 4)
                                            Text(store.settings.disabledTools.contains(tool.name) ? "已停用" : ToolPolicyResolver.resolve(tool.name, mode: mode, settings: store.settings).title)
                                                .font(.caption).fixedSize().foregroundStyle(.secondary)
                                        }
                                        Text(tool.desc).font(.callout).foregroundStyle(.secondary)
                                        if ToolRunner.dangerousTools.contains(tool.name) {
                                            Label("危险工具", systemImage: "exclamationmark.triangle").font(.caption)
                                        }
                                        if tool.name == GuardDemo.toolName {
                                            let policy = ToolPolicyResolver.resolve(tool.name, mode: .plan, settings: store.settings)
                                            LabeledContent("演示策略 · 计划模式", value: policy.title)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(.leading, 10).padding(.vertical, 8)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16).onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .mynaResourcesChanged)) { _ in refresh() }
    }

    private func refresh() { catalog = ToolRunner.catalog().sorted { $0.name < $1.name } }
}
