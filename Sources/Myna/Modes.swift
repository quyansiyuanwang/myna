import Foundation

/// 会话运行模式。按会话保存，不改变模型与采样参数。
enum ChatMode: String, Codable, CaseIterable, Sendable {
    case normal
    case plan
    case goal
    case create

    var title: String {
        switch self {
        case .normal: return "普通"
        case .plan: return "计划"
        case .goal: return "目标"
        case .create: return "创造"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "bubble.left.and.bubble.right"
        case .plan: return "list.bullet.clipboard"
        case .goal: return "target"
        case .create: return "wand.and.stars"
        }
    }

    /// 计划模式只读工具白名单。新增工具必须显式加入，否则默认拒绝。
    static let readOnlyTools: Set<String> = [
        "read_file", "list_dir", "find_files", "search_text",
        "git_status", "git_diff", "git_log",
        "web_search", "fetch_url",
        "read_screen", "screenshot", "list_windows", "view_image",
        "list_running_apps", "system_info", "get_datetime", "get_weather",
        "now_playing", "get_volume", "clipboard_read",
        "read_skill", "list_skills", "wait",
    ]

    /// 当前模式允许的工具；nil 表示不限制。
    var allowedTools: Set<String>? {
        switch self {
        case .plan: return Self.readOnlyTools
        case .normal, .goal, .create: return nil
        }
    }

    /// 追加到系统提示词的模式说明。
    func promptAddendum(goal: Goal?) -> String {
        switch self {
        case .normal:
            return ""
        case .plan:
            return """

            ## 计划模式
            你现在处于计划模式，只允许只读调查：读取文件、搜索、查看屏幕、查询资料。严禁写文件、删除/移动、执行命令或 AppleScript、控制鼠标键盘、修改配置、安装技能/插件/MCP。
            先澄清必要的不确定点；然后输出可直接执行的计划，包含：
            1. 目标与约束
            2. 现状与证据（涉及的文件/命令）
            3. 分步计划（每一步的文件、命令或工具）
            4. 验证方式与风险/回滚
            写完计划就停住，等待用户批准；不要声称已经执行，也不要尝试绕过只读限制。
            """
        case .goal:
            let text = goal?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "（尚未设置目标）"
            return """

            ## 目标模式
            当前目标：\(text)
            持续执行直到目标完成；不要停在中间状态，除非确实需要用户提供信息。
            每轮结束前调用 goal_report 汇报状态：progress / done / blocked，并写一句摘要。
            已完成时调用 goal_report(status: done)；受阻且无法自行解决时调用 goal_report(status: blocked)。
            不要重复已完成的步骤；每轮先检查已有结果。
            """
        case .create:
            return """

            ## 创造模式
            你处于创造模式：可以写文件、生成文档/代码/技能/插件/MCP 配置。
            动手前先列出将创建的交付物、文件路径与验证方式；用户确认后执行。
            完成后自检（打开/读取/运行验证），并列出最终文件路径。不要改动无关文件。
            """
        }
    }
}

/// 目标模式绑定的持久目标。
struct Goal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case active, paused, done, blocked
    }

    var text: String
    var status: Status = .active
    var iterations: Int = 0
    var maxIterations: Int = 8
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var isActive: Bool { status == .active }
}

/// 一次上下文压缩的结果，供界面展示与撤销。
struct CompactionRecord: Codable, Equatable, Sendable {
    var summary: String
    var keptTurns: Int
    var beforeTokens: Int
    var afterTokens: Int
    var date: Date = Date()
    var model: String = ""
    /// true 表示摘要生成失败，实际走的是直接截断。
    var fallback: Bool = false
}

/// 用户附加的文件或文件夹。只保存路径，不复制内容。
struct Attachment: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var path: String
    var name: String
    var isDirectory: Bool = false
    var byteCount: Int64 = 0

    init(path: String, name: String? = nil, isDirectory: Bool = false, byteCount: Int64 = 0) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.byteCount = byteCount
    }
}

/// 工具权限策略。
enum ToolPolicy: String, Codable, CaseIterable, Sendable {
    case allow, ask, deny

    var title: String {
        switch self {
        case .allow: return "允许"
        case .ask: return "询问"
        case .deny: return "拒绝"
        }
    }
}
