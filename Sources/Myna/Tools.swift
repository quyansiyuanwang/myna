import Foundation
import PiKit

/// 提供给大模型调用的本机操作工具集（近似 Siri 的能力）
enum ToolRunner {

    /// 子代理默认禁用的工具：避免子代理递归派生新的子代理。
    static let subAgentExcluded = ["run_subagent", "run_subagents"]

    // MARK: - 工具声明

    static func definitions(disabled: [String] = []) -> [[String: Any]] {
        var list: [[String: Any]] = []
        func fn(_ name: String, _ desc: String, props: [String: Any] = [:], required: [String] = []) {
            var params: [String: Any] = ["type": "object", "properties": props]
            if !required.isEmpty { params["required"] = required }
            list.append(["type": "function",
                         "function": ["name": name, "description": desc, "parameters": params]])
        }
        let s: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let i: (String) -> [String: Any] = { ["type": "integer", "description": $0] }
        let sa: (String) -> [String: Any] = { ["type": "array", "items": ["type": "string"], "description": $0] }
        let b: (String) -> [String: Any] = { ["type": "boolean", "description": $0] }

        fn("open_app", "打开 Mac 上的应用程序", props: ["name": s("应用名称，如 计算器 / Google Chrome / 微信")], required: ["name"])
        fn("quit_app", "退出应用程序", props: ["name": s("应用名称")], required: ["name"])
        fn("open_url", "在默认浏览器打开网址", props: ["url": s("完整网址，含 https://")], required: ["url"])
        fn("web_search", "用浏览器搜索关键词", props: ["query": s("搜索词")], required: ["query"])
        fn("run_shortcut", "运行系统「快捷指令」", props: ["name": s("快捷指令名称"), "input": s("可选，传给快捷指令的文本输入")], required: ["name"])
        fn("list_shortcuts", "列出本机已有的快捷指令")
        fn("set_volume", "设置系统输出音量（0-100）", props: ["level": i("音量百分比")], required: ["level"])
        fn("get_volume", "获取当前系统音量")
        fn("set_brightness", "调节屏幕亮度，direction 为 up 或 down，steps 为步数(默认1)", props: ["direction": s("up 或 down"), "steps": i("步数，默认1")], required: ["direction"])
        fn("music_control", "控制「音乐」App", props: ["action": s("play/pause/playpause/next/previous"), "query": s("可选，按名称播放的歌曲/艺人")], required: ["action"])
        fn("now_playing", "查看音乐 App 当前播放的歌曲")
        fn("create_reminder", "在「提醒事项」创建提醒", props: ["title": s("标题"), "notes": s("备注"), "due": s("可选截止时间，格式 yyyy-MM-dd HH:mm")], required: ["title"])
        fn("create_calendar_event", "在「日历」创建日程", props: ["title": s("标题"), "start": s("开始时间 yyyy-MM-dd HH:mm"), "end": s("结束时间 yyyy-MM-dd HH:mm")], required: ["title", "start", "end"])
        fn("get_datetime", "获取当前日期时间")
        fn("system_info", "获取电池、磁盘、运行时长等系统信息")
        fn("clipboard_read", "读取剪贴板内容")
        fn("clipboard_write", "写入剪贴板", props: ["text": s("要写入的文本")], required: ["text"])
        fn("speak", "让电脑朗读一段文字", props: ["text": s("要朗读的文字")], required: ["text"])
        fn("run_applescript", "执行一段 AppleScript 脚本（高级）", props: ["source": s("AppleScript 源码")], required: ["source"])
        fn("shell_command", "执行一条 shell 命令（高级）", props: ["command": s("命令")], required: ["command"])
        fn("lock_screen", "锁定屏幕")
        fn("screenshot", "截屏保存到桌面", props: ["path": s("可选，保存路径")])
        fn("type_text", "模拟键盘输入一段文字（需辅助功能权限）", props: ["text": s("要输入的文字")], required: ["text"])
        fn("list_running_apps", "列出当前正在运行的应用")
        fn("get_weather", "查询城市天气", props: ["city": s("城市名，如 Beijing")], required: ["city"])
        fn("list_skills", "列出本机已安装的技能")
        fn("read_skill", "读取某个技能的完整说明", props: ["name": s("技能 id 或名称")], required: ["name"])
        // 文件 / 目录（编码代理能力）
        fn("read_file", "读取文本文件内容，带行号，可选起始行 offset 与行数上限 limit",
           props: ["path": s("文件路径，支持 ~ 与相对工作目录的路径"),
                   "offset": i("可选，起始行号（从 1 开始）"),
                   "limit": i("可选，最多读取的行数")],
           required: ["path"])
        fn("write_file", "写入文本文件，可选自动创建父目录",
           props: ["path": s("文件路径"),
                   "content": s("要写入的完整文本内容"),
                   "create_dirs": b("可选，父目录不存在时是否自动创建（默认 false）")],
           required: ["path", "content"])
        fn("edit_file", "在文件中做精确字符串替换（仅唯一匹配或 replace_all）",
           props: ["path": s("文件路径"),
                   "old_string": s("要被替换的原文（需精确匹配）"),
                   "new_string": s("替换为的新内容"),
                   "replace_all": b("可选，替换全部匹配（默认 false，仅唯一匹配）")],
           required: ["path", "old_string", "new_string"])
        fn("list_dir", "列出目录内容（目录在前，带类型与大小）",
           props: ["path": s("可选，目录路径；默认当前工作目录")])
        fn("find_files", "按 glob 搜索文件（支持 *、?、**）",
           props: ["pattern": s("glob 模式，如 **/*.swift"),
                   "path": s("可选，搜索基准目录；默认当前工作目录"),
                   "max_results": i("可选，最多返回条数（默认 200）")],
           required: ["pattern"])
        fn("search_text", "递归搜索文件内容，输出 file:line: 文本",
           props: ["query": s("要搜索的文本"),
                   "path": s("可选，搜索基准目录；默认当前工作目录"),
                   "glob": s("可选，只搜索匹配 glob 的文件"),
                   "max_results": i("可选，最多返回条数（默认 200）"),
                   "case_sensitive": b("可选，区分大小写（默认 false）")],
           required: ["query"])
        fn("make_dir", "创建目录（包含父目录）", props: ["path": s("目录路径")], required: ["path"])
        fn("move_path", "移动或重命名文件 / 目录",
           props: ["from": s("源路径"), "to": s("目标路径")], required: ["from", "to"])
        fn("delete_path", "删除文件或目录（危险工具）",
           props: ["path": s("要删除的路径"),
                   "recursive": b("可选，删除目录时需设为 true")],
           required: ["path"])
        // Git（项目感知）
        fn("git_status", "查看 Git 仓库状态（分支与改动清单）",
           props: ["path": s("可选，仓库路径；默认当前工作目录")])
        fn("git_diff", "查看 Git 工作区改动（不包含颜色转义）",
           props: ["path": s("可选，仓库路径"),
                   "staged": b("可选，查看已暂存改动（git diff --staged）")])
        fn("git_log", "查看 Git 提交历史（单行）",
           props: ["path": s("可选，仓库路径"),
                   "limit": i("可选，返回条数（默认 20）")])
        fn("git_commit", "暂存并提交 Git 改动（危险工具，会写入历史）",
           props: ["message": s("提交信息"),
                   "path": s("可选，仓库路径"),
                   "add_all": b("可选，提交前 git add -A（默认 true）")],
           required: ["message"])
        // 通用命令执行（构建 / 测试等）
        fn("run_command", "在工作目录执行 shell 命令（构建 / 测试等），返回合并的标准输出与错误（危险工具）",
           props: ["command": s("要执行的 shell 命令"),
                   "cwd": s("可选，命令工作目录；默认工作目录"),
                   "timeout_seconds": i("可选，超时秒数（默认取 command_timeout_seconds）")],
           required: ["command"])
        // 子代理：独立上下文执行任务 / 并行执行多个任务
        fn("run_subagent",
           "把一个自包含的任务交给子代理执行。子代理拥有独立的上下文、系统提示与本机工具，返回其最终结果。适合较长、需多步完成、且不希望污染当前对话的任务。",
           props: ["task": s("要完成的任务，尽量具体并包含必要上下文"),
                   "system_prompt": s("可选，覆盖子代理的系统提示词"),
                   "tools": sa("可选，仅允许子代理使用的工具名列表（默认继承全部已启用工具）"),
                   "max_rounds": i("可选，子代理最大工具轮数（0 = 不限制）"),
                   "timeout_seconds": i("可选，子代理超时秒数")],
           required: ["task"])
        fn("run_subagents",
           "并行运行多个子代理，每个子代理独立完成一个任务，返回全部结果。适合可拆分并行处理的工作。",
           props: ["tasks": sa("任务列表，每个任务交给一个子代理"),
                   "system_prompt": s("可选，覆盖所有子代理的系统提示词"),
                   "tools": sa("可选，仅允许子代理使用的工具名列表")],
           required: ["tasks"])
        // MCP 服务器工具（名称形如 mcp__<server>__<tool>）
        for tool in MCPManager.shared.tools() {
            list.append(["type": "function",
                         "function": ["name": tool.name,
                                      "description": tool.description,
                                      "parameters": tool.schema.foundationValue]])
        }
        let disabledSet = Set(disabled)
        return list.filter { d in
            guard let fn = d["function"] as? [String: Any], let n = fn["name"] as? String else { return true }
            return !disabledSet.contains(n)
        }
    }

    /// 工具目录（名称 + 说明），供设置界面展示
    static func catalog() -> [(name: String, desc: String)] {
        definitions(disabled: []).compactMap { d in
            guard let fn = d["function"] as? [String: Any],
                  let n = fn["name"] as? String,
                  let desc = fn["description"] as? String else { return nil }
            return (n, desc)
        }
    }

    // MARK: - Swift 包运行时适配（PiKit.FunctionTool）

    /// 把 `definitions()` 声明的 JSON schema 包装成 `PiKit.FunctionTool`。
    /// 执行体复用 `ToolRunner.run`，并尊重 `disabledTools`。
    static func packageTools(disabled: [String] = [], only: [String]? = nil) -> [any AgentTool] {
        let allowed = only.map(Set.init)
        return definitions(disabled: disabled).compactMap { d in
            guard let fn = d["function"] as? [String: Any],
                  let name = fn["name"] as? String,
                  let desc = fn["description"] as? String,
                  let params = fn["parameters"] as? [String: Any],
                  let schema = jsonValue(params) else { return nil }
            if let allowed, !allowed.contains(name) { return nil }
            return FunctionTool(name: name, description: desc, parametersJSONSchema: schema) { call, _ in
                // MCP 工具走真正的异步路径，避免占用线程
                if name.hasPrefix("mcp__") {
                    do {
                        let text = try await MCPManager.shared.call(namespaced: name, arguments: call.arguments)
                        return ToolResult(text: text)
                    } catch {
                        return ToolResult(text: "MCP 调用失败：\(error.localizedDescription)", isError: true)
                    }
                }
                let args = (call.arguments.objectValue ?? [:]).reduce(into: [String: Any]()) { acc, pair in
                    acc[pair.key] = pair.value.foundationValue
                }
                // 子代理走异步路径，直接 await，不阻塞线程
                if ToolRunner.subAgentExcluded.contains(name) {
                    return ToolResult(text: await SubAgentRunner.handleAsync(name, args: args))
                }
                return ToolResult(text: ToolRunner.run(name: name, args: args))
            }
        }
    }

    /// 把 Foundation JSON 字典转成 `PiAI.JSONValue`（失败返回 nil）。
    private static func jsonValue(_ object: [String: Any]) -> JSONValue? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let schema = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return schema
    }

    // MARK: - 执行分发

    static func run(name: String, args: [String: Any]) -> String {
        func str(_ k: String) -> String { args[k] as? String ?? "" }
        func int(_ k: String, _ def: Int = 0) -> Int {
            if let v = args[k] as? Int { return v }
            if let v = args[k] as? Double { return Int(v) }
            if let v = args[k] as? String, let x = Int(v) { return x }
            return def
        }
        // MCP 工具：同步桥接，带超时，绝不阻塞主线程
        if name.hasPrefix("mcp__") {
            return MCPManager.shared.callSync(namespaced: name, arguments: MCPManager.jsonValue(from: args))
        }
        // 危险工具：按 confirm_dangerous_tools 设置拒绝执行，要求模型先取得用户确认
        if SettingsStore.shared.settings.confirmDangerousTools, ToolRunner.dangerousTools.contains(name) {
            return "危险工具「\(name)」已被 confirm_dangerous_tools 设置拒绝执行。请先向用户说明将要执行的操作并获得明确确认；用户确认后，需在设置中关闭 confirm_dangerous_tools 才能继续执行。"
        }
        // 文件 / 目录 / 搜索 / Git / 命令执行工具
        if ToolRunner.codingToolNames.contains(name) {
            return ToolRunner.handleCoding(name, args: args)
        }
        // 子代理：同步桥接，带超时（有界阻塞，不会无限期挂起）
        if ToolRunner.subAgentExcluded.contains(name) {
            return SubAgentRunner.handle(name, args: args)
        }
        switch name {
        case "open_app":        return openApp(str("name"))
        case "quit_app":
            let n = appName(str("name"))
            let quitScript = "tell application " + asString(n) + " to quit"
            // 优先用 pkill（无需自动化权限），失败再退回 AppleScript
            return sh("pkill -x \(q(n)) || osascript -e \(q(quitScript))", timeout: 8)
        case "open_url":        return sh("open \(q(str("url")))")
        case "web_search":      return sh("open \(q("https://www.google.com/search?q=" + urlEncode(str("query"))))")
        case "run_shortcut":    return sh("shortcuts run \(q(str("name")))", stdin: args["input"] as? String)
        case "list_shortcuts":  return sh("shortcuts list")

        case "set_volume":      return osa("set volume output volume \(max(0, min(100, int("level", 50))))")
        case "get_volume":      return osa("output volume of (get volume settings)")
        case "set_brightness":
            let code = (str("direction").lowercased() == "down") ? "145" : "144"
            let times = max(1, min(16, int("steps", 1)))
            return osa("tell application \"System Events\"\nrepeat \(times) times\nkey code \(code)\nend repeat\nend tell")

        case "music_control":   return music(action: str("action"), query: str("query"))
        case "now_playing":     return nowPlaying()

        case "create_reminder": return createReminder(title: str("title"), notes: str("notes"), due: str("due"))
        case "create_calendar_event": return createEvent(title: str("title"), start: str("start"), end: str("end"))

        case "get_datetime":    return sh("date '+%Y-%m-%d %H:%M:%S %A'")
        case "system_info":     return systemInfo()
        case "clipboard_read":  return sh("pbpaste")
        case "clipboard_write": return sh("pbcopy", stdin: str("text"))
        case "speak":           return sh("say \(q(str("text")))")
        case "run_applescript": return osa(str("source"))
        case "shell_command":   return sh(str("command"))
        case "lock_screen":     return osa("tell application \"System Events\" to keystroke \"q\" using {control down, command down}")
        case "screenshot":
            let path = str("path").isEmpty ? "~/Desktop/Myna-\(Int(Date().timeIntervalSince1970)).png" : str("path")
            let p = NSString(string: path).expandingTildeInPath
            return sh("screencapture -x \(q(p))") + " -> \(p)"
        case "type_text":       return osa("tell application \"System Events\" to keystroke \(asString(str("text")))")
        case "list_running_apps": return osa("tell application \"System Events\" to get name of every process whose background only is false")
        case "get_weather":     return sh("curl -s --max-time 12 \(q("https://wttr.in/" + urlEncode(str("city")) + "?format=%l:+%c+%t+%w+%h+%p"))")
        case "list_skills":
            let skills = LocalResources.skills()
            if skills.isEmpty { return "（未安装技能，可在 ~/.config/myna/skills 添加）" }
            return skills.map { "- \($0.name)（id: \($0.id)）：\($0.description)" }.joined(separator: "\n")
        case "read_skill":
            guard let skill = LocalResources.skill(named: str("name")) else {
                return "未找到技能：\(str("name"))"
            }
            return "# \(skill.name)\n\n\(skill.body)"
        default:                return "未知工具: \(name)"
    }
    }

    // MARK: - 具体实现

    /// 常见中文应用名映射为系统实际名称
    static func appName(_ raw: String) -> String {
        let map = ["计算器": "Calculator", "微信": "WeChat", "访达": "Finder", "音乐": "Music",
                   "日历": "Calendar", "提醒事项": "Reminders", "系统设置": "System Settings",
                   "系统偏好设置": "System Settings", "浏览器": "Safari", "备忘录": "Notes",
                   "终端": "Terminal", "照片": "Photos", "地图": "Maps", "邮件": "Mail",
                   "信息": "Messages", "时钟": "Clock", "天气": "Weather", "预览": "Preview"]
        return map[raw] ?? raw
    }

    private static func openApp(_ raw: String) -> String {
        let n = appName(raw)
        let r = sh("open -a \(q(n))")
        return r.contains("Unable to find") ? "找不到应用「\(raw)」" : r
    }

    private static func music(action: String, query: String) -> String {
        if !query.isEmpty {
            let script = """
            tell application "Music"
                if not running then launch
                set matches to (every track whose name contains \(asString(query)))
                if (count of matches) > 0 then
                    play item 1 of matches
                    return "正在播放: " & (name of current track)
                else
                    return "没有找到: \(query)"
                end if
            end tell
            """
            let r = osa(script)
            if !r.contains("没有找到") { return r }
        }
        let cmd: String
        switch action.lowercased() {
        case "play": cmd = "play"
        case "pause": cmd = "pause"
        case "next": cmd = "next track"
        case "previous": cmd = "previous track"
        default: cmd = "playpause"
        }
        return osa("tell application \"Music\"\nif not running then launch\n\(cmd)\nend tell")
    }

    private static func nowPlaying() -> String {
        osa("""
        tell application "Music"
            if player state is playing then
                return (name of current track) & " - " & (artist of current track)
            else
                return "当前没有在播放"
            end if
        end tell
        """)
    }

    private static func createReminder(title: String, notes: String, due: String) -> String {
        var script = "tell application \"Reminders\"\nset r to make new reminder with properties {name:\(asString(title))}\n"
        if !notes.isEmpty { script += "set body of r to \(asString(notes))\n" }
        if let lines = dateLines(due, into: "theDate") {
            script += lines + "\nset due date of r to theDate\n"
        }
        script += "return \"已创建提醒: \" & \(asString(title))\nend tell"
        return osa(script)
    }

    private static func createEvent(title: String, start: String, end: String) -> String {
        guard let sLines = dateLines(start, into: "sd"), let eLines = dateLines(end, into: "ed") else {
            return "时间格式应为 yyyy-MM-dd HH:mm"
        }
        return osa("""
        tell application "Calendar"
            tell calendar 1
                \(sLines)
                \(eLines)
                make new event with properties {summary:\(asString(title)), start date:sd, end date:ed}
            end tell
            return "已创建日程: \(title)"
        end tell
        """)
    }

    private static func systemInfo() -> String {
        let batt = sh("pmset -g batt")
        let disk = sh("df -h / | tail -1")
        let up = sh("uptime")
        return "电池: \(batt)\n磁盘: \(disk)\n运行: \(up)"
    }

    // MARK: - 底层工具

    @discardableResult
    static func sh(_ command: String, stdin: String? = nil, timeout: TimeInterval = 30) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inp = Pipe()
        p.standardInput = inp
        do { try p.run() } catch { return "执行失败: \(error.localizedDescription)" }

        let pid = p.processIdentifier
        let timedOut = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        timedOut.initialize(to: false)
        let watchdog = DispatchWorkItem {
            guard p.isRunning else { return }
            timedOut.pointee = true
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        inp.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        var text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut.pointee {
            text = (text.isEmpty ? "" : text + "；") + "命令超时（可能需要在 系统设置→隐私与安全性→自动化 中授权）"
        }
        if text.isEmpty { text = p.terminationStatus == 0 ? "完成" : "退出码 \(p.terminationStatus)" }
        timedOut.deallocate()
        return String(text.prefix(4000))
    }

    static func osa(_ script: String) -> String { sh("osascript -e \(q(script))") }

    /// shell 单引号转义
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// AppleScript 字符串字面量
    static func asString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// "yyyy-MM-dd HH:mm" -> 生成赋值变量 varName 为对应日期的 AppleScript 语句
    private static func dateLines(_ s: String, into varName: String) -> String? {
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = f.date(from: s) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return """
        set \(varName) to current date
        set year of \(varName) to \(c.year!)
        set month of \(varName) to \(c.month!)
        set day of \(varName) to \(c.day!)
        set hours of \(varName) to \(c.hour!)
        set minutes of \(varName) to \(c.minute!)
        set seconds of \(varName) to 0
        """
    }
}

// MARK: - PiKit 适配

// 本机工具经 `ToolRunner.packageTools` 以 `PiKit.FunctionTool` 暴露给
// `PiAgentCore.Agent`：声明取自 `ToolRunner.definitions()` 的 JSON schema，
// 执行时把模型给出的 `JSONValue` 参数还原为 Foundation 字典后交给
// `ToolRunner.run`。

extension JSONValue {
    /// 转回 `ToolRunner.run` 需要的 Foundation 表示（String / Int / Double /
    /// Bool / Array / Dictionary / NSNull）。
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map { $0.foundationValue }
        case .object(let object): return object.mapValues { $0.foundationValue }
        }
    }
}
