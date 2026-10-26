import Foundation
import AppKit
import PiKit

/// 工具权限的默认规则与覆盖。
enum ToolPolicyResolver {
    /// 写操作、命令、电脑控制、自我修改、MCP 与子代理默认询问。
    static let askTools: Set<String> = [
        "write_file", "edit_file", "make_dir", "move_path", "delete_path",
        "git_commit", "run_command", "shell_command", "run_applescript",
        "open_app", "quit_app", "open_url", "run_shortcut",
        "set_volume", "set_brightness", "music_control", "lock_screen",
        "clipboard_write", "create_reminder", "create_calendar_event", "speak",
        "screenshot", "read_screen", "list_windows", "activate_app",
        "mouse_move", "mouse_click", "mouse_drag", "scroll", "key_press", "type_text",
        "run_subagent", "run_subagents",
        "myna_settings", "myna_permissions", "myna_data",
        "skill_write", "skill_delete", "mcp_manage", "plugin_manage",
    ]

    static func resolve(_ tool: String, mode: ChatMode, settings: AppSettings) -> ToolPolicy {
        // 计划模式：只读白名单之外一律拒绝，优先级最高。
        if mode == .plan, !ChatMode.readOnlyTools.contains(tool) {
            return .deny
        }
        if settings.disabledTools.contains(tool) { return .deny }
        if let raw = settings.toolPolicies[tool], let policy = ToolPolicy(rawValue: raw) {
            return policy
        }
        if tool.hasPrefix("mcp__") { return .ask }
        if ChatMode.readOnlyTools.contains(tool) { return .allow }
        if askTools.contains(tool) { return .ask }
        return .allow
    }

    /// 给界面使用的「默认策略」：忽略显式覆盖与模式。
    static func defaultPolicy(_ tool: String) -> ToolPolicy {
        if ChatMode.readOnlyTools.contains(tool) { return .allow }
        if askTools.contains(tool) { return .ask }
        if tool.hasPrefix("mcp__") { return .ask }
        return .allow
    }
}

/// 一次等待用户决定的权限请求。
@MainActor
final class PermissionPrompt: ObservableObject, Identifiable {
    let id = UUID()
    let tool: String
    let summary: String
    let mode: ChatMode

    init(tool: String, summary: String, mode: ChatMode) {
        self.tool = tool
        self.summary = summary
        self.mode = mode
    }
}

/// 串行处理工具授权弹窗；挂起工具执行直到用户选择或超时。
@MainActor
final class ToolPermissionCenter: ObservableObject {
    static let shared = ToolPermissionCenter()

    @Published var pending: PermissionPrompt?

    private var queue: [PermissionPrompt] = []
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    private var interactive: Bool {
        if ProcessInfo.processInfo.environment["MYNA_NONINTERACTIVE"] == "1" { return false }
        return Bundle.main.bundleIdentifier != nil
    }

    func request(tool: String, arguments: JSONValue?, mode: ChatMode) async -> Bool {
        let settings = SettingsStore.shared.settings
        switch ToolPolicyResolver.resolve(tool, mode: mode, settings: settings) {
        case .allow:
            return true
        case .deny:
            return false
        case .ask:
            break
        }
        guard interactive else { return false }

        let summary = arguments.map { PackageRuntime.describe($0) } ?? ""
        let prompt = PermissionPrompt(tool: tool,
                                      summary: summary.isEmpty ? "（无参数）" : String(summary.prefix(800)),
                                      mode: mode)
        return await withCheckedContinuation { continuation in
            continuations[prompt.id] = continuation
            queue.append(prompt)
            presentNextIfNeeded()
        }
    }

    /// 同步版本，供内置运行时的 `ToolRunner.run` 使用。
    func requestBlocking(tool: String, arguments: [String: Any], mode: ChatMode) -> Bool {
        let settings = SettingsStore.shared.settings
        switch ToolPolicyResolver.resolve(tool, mode: mode, settings: settings) {
        case .allow: return true
        case .deny: return false
        case .ask: break
        }
        guard interactive, Thread.isMainThread else { return false }

        let summary = arguments.isEmpty
            ? "（无参数）"
            : String(String(describing: arguments).prefix(800))
        let alert = NSAlert()
        alert.messageText = "允许 Myna 调用「\(tool)」？"
        alert.informativeText = summary
        alert.alertStyle = .warning
        alert.addButton(withTitle: "允许一次")
        alert.addButton(withTitle: "始终允许")
        alert.addButton(withTitle: "拒绝")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return true }
        if response == .alertSecondButtonReturn {
            SettingsStore.shared.settings.toolPolicies[tool] = ToolPolicy.allow.rawValue
            return true
        }
        return false
    }

    func resolve(id: UUID, allow: Bool, always: Bool) {
        guard let prompt = pending, prompt.id == id else { return }
        if allow, always {
            SettingsStore.shared.settings.toolPolicies[prompt.tool] = ToolPolicy.allow.rawValue
        }
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        pending = nil
        let continuation = continuations.removeValue(forKey: id)
        continuation?.resume(returning: allow)
        presentNextIfNeeded()
    }

    /// 用户中止运行时清空所有等待中的授权，避免工具任务挂到超时。
    func cancelPending() {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        pending = nil
        let ids = continuations.keys
        let pendingContinuations = continuations
        continuations.removeAll()
        queue.removeAll()
        for id in ids { pendingContinuations[id]?.resume(returning: false) }
    }

    private func presentNextIfNeeded() {
        guard pending == nil, !queue.isEmpty else { return }
        let prompt = queue.removeFirst()
        pending = prompt
        AppDelegate.shared?.showWindow(startVoice: false)
        let timeout = SettingsStore.shared.settings.permissionPromptTimeoutSeconds
        timeoutTasks[prompt.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, timeout)) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.resolve(id: prompt.id, allow: false, always: false) }
        }
    }
}

/// 内置运行时的同步授权桥：仅主线程可用，避免引入挂起。
enum ToolPermissionBridge {
    static func blocking(tool: String, arguments: [String: Any], mode: ChatMode) -> Bool {
        let settings = SettingsStore.shared.settings
        switch ToolPolicyResolver.resolve(tool, mode: mode, settings: settings) {
        case .allow: return true
        case .deny: return false
        case .ask: break
        }
        if ProcessInfo.processInfo.environment["MYNA_EXPLICIT_TOOL"] == "1" { return true }
        guard Thread.isMainThread, Bundle.main.bundleIdentifier != nil else { return false }
        let summary = arguments.isEmpty ? "（无参数）" : String(String(describing: arguments).prefix(800))
        let alert = NSAlert()
        alert.messageText = "允许 Myna 调用「\(tool)」？"
        alert.informativeText = summary
        alert.alertStyle = .warning
        alert.addButton(withTitle: "允许一次")
        alert.addButton(withTitle: "始终允许")
        alert.addButton(withTitle: "拒绝")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            SettingsStore.shared.settings.toolPolicies[tool] = ToolPolicy.allow.rawValue
            return true
        default:
            return false
        }
    }
}

/// 包运行时的工具包装：执行前走权限检查。
struct PermissionGatedTool: AgentTool {
    let base: any AgentTool
    let mode: ChatMode

    var name: String { base.name }
    var description: String { base.description }
    var parametersJSONSchema: JSONValue { base.parametersJSONSchema }

    func execute(_ call: ToolCall, onUpdate: ((ToolResult) -> Void)?) async throws -> ToolResult {
        let allowed = await ToolPermissionCenter.shared.request(
            tool: base.name, arguments: call.arguments, mode: mode
        )
        guard allowed else {
            return ToolResult(
                text: "用户拒绝了工具「\(base.name)」；请调整方案，不要重复调用。"
                    + "如果是计划模式，请只输出计划并等待批准。",
                isError: true
            )
        }
        return try await base.execute(call, onUpdate: onUpdate)
    }
}
