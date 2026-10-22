import Foundation

/// 编码代理能力：文件 / 目录 / 搜索 / Git / 命令执行工具。
///
/// 这些工具在 `ToolRunner.definitions()` 里声明，由 `ToolRunner.run` 路由到本文件。
/// 除 `run_command` 外均优先使用 Foundation 原生实现，避免依赖外部命令；
/// 所有路径支持 `~`，相对路径以 ``AppSettings/workingDirectory``（默认用户主目录）为基准。
/// 任何失败都返回可读中文说明，绝不抛出崩溃。
extension ToolRunner {

    /// 危险工具集合：设置界面显示「危险」徽标；当
    /// ``AppSettings/confirmDangerousTools`` 为 true 时直接拒绝执行。
    static let dangerousTools: Set<String> = [
        "shell_command", "run_applescript", "delete_path", "git_commit", "run_command",
        // 电脑控制与自我配置会直接改变用户环境，开启确认开关时一并拦截。
        "mouse_click", "mouse_drag", "key_press", "type_text", "myna_settings",
    ]

    /// 本文件负责的工具名（供 `ToolRunner.run` 路由）。
    static let codingToolNames: Set<String> = [
        "read_file", "write_file", "edit_file", "list_dir", "find_files",
        "search_text", "make_dir", "move_path", "delete_path",
        "git_status", "git_diff", "git_log", "git_commit", "run_command",
    ]

    /// 递归遍历时跳过的重目录，避免搜索变慢或误入依赖目录。
    private static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", ".swiftpm",
    ]

    // MARK: - 路径解析

    /// 工作目录：优先会话传入的 `override`，其次
    /// ``AppSettings/workingDirectory``，最后回落到用户主目录。
    /// `override` 为空（nil 或空白）时视为未设置。
    static func workingDirectory(_ override: String? = nil) -> String {
        let own = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = own.isEmpty
            ? SettingsStore.shared.settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            : own
        if value.isEmpty { return NSString(string: "~").expandingTildeInPath }
        return NSString(string: value).expandingTildeInPath
    }

    /// 展开 `~`；相对路径解析到工作目录。
    static func resolvePath(_ raw: String, base: String? = nil) -> String {
        let expanded = NSString(string: raw).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        let dir = base ?? workingDirectory()
        return ((dir as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    // MARK: - 执行分发

    /// 执行本文件声明的工具，返回可读中文结果。
    ///
    /// `cwd` 是调用方（会话 / 子代理）解析好的工作目录；为空时使用应用默认。
    static func handleCoding(_ name: String, args: [String: Any], cwd: String? = nil) -> String {
        let settings = SettingsStore.shared.settings
        let base = workingDirectory(cwd)
        func str(_ k: String) -> String { args[k] as? String ?? "" }
        func int(_ k: String, _ def: Int = 0) -> Int {
            if let v = args[k] as? Int { return v }
            if let v = args[k] as? Double { return Int(v) }
            if let v = args[k] as? String, let x = Int(v) { return x }
            return def
        }
        func bool(_ k: String, _ def: Bool = false) -> Bool {
            if let v = args[k] as? Bool { return v }
            if let v = args[k] as? Int { return v != 0 }
            if let v = args[k] as? String { return ["true", "1", "yes"].contains(v.lowercased()) }
            return def
        }

        switch name {
        case "read_file":
            return readFile(path: str("path"),
                            offset: args["offset"] == nil ? nil : int("offset", 1),
                            limit: args["limit"] == nil ? nil : int("limit"),
                            settings: settings, base: base)
        case "write_file":
            return writeFile(path: str("path"), content: str("content"),
                             createDirs: bool("create_dirs"), base: base)
        case "edit_file":
            return editFile(path: str("path"), old: str("old_string"), new: str("new_string"),
                            replaceAll: bool("replace_all"), base: base)
        case "list_dir":
            return listDir(path: str("path"), base: base)
        case "find_files":
            return findFiles(pattern: str("pattern"), path: str("path"),
                             maxResults: args["max_results"] == nil ? nil : int("max_results"),
                             base: base)
        case "search_text":
            return searchText(query: str("query"), path: str("path"), glob: str("glob"),
                              maxResults: args["max_results"] == nil ? nil : int("max_results"),
                              caseSensitive: bool("case_sensitive"), settings: settings, base: base)
        case "make_dir":
            return makeDir(path: str("path"), base: base)
        case "move_path":
            return movePath(from: str("from"), to: str("to"), base: base)
        case "delete_path":
            return deletePath(path: str("path"), recursive: bool("recursive"), base: base)
        case "git_status":
            return git(["status", "--porcelain=v1", "--branch"], path: str("path"),
                       settings: settings, base: base)
        case "git_diff":
            return gitDiff(path: str("path"), staged: bool("staged"), settings: settings, base: base)
        case "git_log":
            return gitLog(path: str("path"), limit: args["limit"] == nil ? nil : int("limit", 20),
                          settings: settings, base: base)
        case "git_commit":
            return gitCommit(path: str("path"), message: str("message"),
                             addAll: bool("add_all", true), settings: settings, base: base)
        case "run_command":
            return runCommand(command: str("command"), cwd: str("cwd"),
                              timeoutSeconds: args["timeout_seconds"] == nil ? nil : int("timeout_seconds"),
                              settings: settings, base: base)
        default:
            return "未知工具：\(name)"
        }
    }

    // MARK: - 文件读写

    private static func readFile(path rawPath: String, offset: Int?, limit: Int?,
                                 settings: AppSettings, base: String) -> String {
        guard !rawPath.isEmpty else { return "缺少参数 path。" }
        let path = resolvePath(rawPath, base: base)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return "文件不存在：\(path)" }
        if isDir.boolValue { return "路径是目录，请用 list_dir：\(path)" }

        let cap = max(1, settings.maxReadBytes)
        var truncated = false
        var data: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            data = handle.readData(ofLength: cap + 1)
            if data.count > cap {
                data = data.prefix(cap)
                truncated = true
            }
        } catch {
            return "读取失败：\(error.localizedDescription)"
        }

        let text = String(decoding: data, as: UTF8.self)
        let allLines = text.components(separatedBy: "\n")
        let start = max(1, offset ?? 1)
        let end: Int
        if let limit, limit > 0 {
            end = min(allLines.count, start - 1 + limit)
        } else {
            end = allLines.count
        }

        var out: [String] = ["# \(path)"]
        if start > allLines.count {
            out.append("（起始行 \(start) 超出文件行数 \(allLines.count)）")
        } else {
            for index in (start - 1)..<end {
                let number = String(format: "%4d", index + 1)
                out.append("\(number) | \(allLines[index])")
            }
        }
        if truncated {
            out.append("（文件超过 max_read_bytes = \(cap) 字节，仅显示前 \(cap) 字节）")
        }
        return out.joined(separator: "\n")
    }

    private static func writeFile(path rawPath: String, content: String, createDirs: Bool, base: String) -> String {
        guard !rawPath.isEmpty else { return "缺少参数 path。" }
        let path = resolvePath(rawPath, base: base)
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            if createDirs {
                do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
                catch { return "创建目录失败：\(error.localizedDescription)" }
            } else {
                return "父目录不存在：\(parent)（可设置 create_dirs=true 自动创建）"
            }
        }
        do {
            try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
        return "已写入 \(path)（\(content.utf8.count) 字节）"
    }

    private static func editFile(path rawPath: String, old: String, new: String, replaceAll: Bool, base: String) -> String {
        guard !rawPath.isEmpty else { return "缺少参数 path。" }
        guard !old.isEmpty else { return "old_string 不能为空。" }
        let path = resolvePath(rawPath, base: base)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "读取失败或文件不存在：\(path)"
        }
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { return "未在 \(path) 找到要替换的内容（old_string 不匹配）。" }
        if count > 1 && !replaceAll {
            return "old_string 在 \(path) 中匹配到 \(count) 处，存在歧义；请提供更精确的内容，或设置 replace_all=true。"
        }
        let updated = text.replacingOccurrences(of: old, with: new)
        do {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
        return "已更新 \(path)（替换 \(replaceAll ? count : 1) 处）"
    }

    // MARK: - 目录与文件系统

    private static func listDir(path rawPath: String, base: String) -> String {
        let path = rawPath.isEmpty ? base : resolvePath(rawPath, base: base)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return "路径不存在：\(path)" }
        guard isDir.boolValue else { return "不是目录：\(path)" }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else {
            return "无法列出目录：\(path)"
        }
        var entries: [(name: String, isDir: Bool, size: Int, link: Bool)] = []
        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: full)
            let type = attrs?[.type] as? FileAttributeType
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            entries.append((name, type == .typeDirectory, size, type == .typeSymbolicLink))
        }
        entries.sort {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if entries.isEmpty { return "目录为空：\(path)" }
        var out = ["# \(path)"]
        for entry in entries {
            let kind = entry.isDir ? "目录" : (entry.link ? "链接" : "文件")
            let sizeText = entry.isDir ? "-" : "\(entry.size) B"
            out.append("\(kind)\t\(sizeText)\t\(entry.name)")
        }
        return out.joined(separator: "\n")
    }

    private static func findFiles(pattern: String, path rawPath: String, maxResults: Int?, base: String) -> String {
        guard !pattern.isEmpty else { return "缺少参数 pattern。" }
        let root = rawPath.isEmpty ? base : resolvePath(rawPath, base: base)
        guard FileManager.default.fileExists(atPath: root) else { return "路径不存在：\(root)" }
        let cap = max(1, maxResults ?? 200)
        var results: [String] = []
        var truncated = false
        walkFiles(base: root) { relative, full in
            if matchesGlob(pattern: pattern, path: relative) {
                results.append(full)
                if results.count >= cap {
                    truncated = true
                    return false
                }
            }
            return true
        }
        if results.isEmpty { return "未找到匹配 \(pattern) 的文件（基准目录：\(root)）" }
        var out = results
        if truncated { out.append("（结果已截断到前 \(cap) 条）") }
        return out.joined(separator: "\n")
    }

    private static func searchText(query: String, path rawPath: String, glob: String,
                                   maxResults: Int?, caseSensitive: Bool, settings: AppSettings,
                                   base: String) -> String {
        guard !query.isEmpty else { return "缺少参数 query。" }
        let root = rawPath.isEmpty ? base : resolvePath(rawPath, base: base)
        guard FileManager.default.fileExists(atPath: root) else { return "路径不存在：\(root)" }
        let cap = max(1, maxResults ?? 200)
        let fileCap = max(1, settings.maxReadBytes)
        let needle = caseSensitive ? query : query.lowercased()
        var matches: [String] = []
        var truncated = false

        walkFiles(base: root) { relative, full in
            if !glob.isEmpty && !matchesGlob(pattern: glob, path: relative) { return true }
            // 过大文件直接跳过，避免占用内存。
            if let size = try? FileManager.default.attributesOfItem(atPath: full)[.size] as? NSNumber,
               size.intValue > fileCap { return true }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else { return true }
            guard data.count <= fileCap else { return true }
            // 简单二进制判断：前 4KB 出现 NUL 字节则跳过。
            if data.prefix(4096).contains(0) { return true }
            guard let text = String(data: data, encoding: .utf8) else { return true }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let haystack = caseSensitive ? line : line.lowercased()
                if haystack.contains(needle) {
                    let clipped = line.count > 400 ? String(line.prefix(400)) + "…" : line
                    matches.append("\(full):\(index + 1): \(clipped)")
                    if matches.count >= cap {
                        truncated = true
                        return false
                    }
                }
            }
            return true
        }

        if matches.isEmpty { return "未找到包含「\(query)」的内容（基准目录：\(root)）" }
        var out = matches
        if truncated { out.append("（结果已截断到前 \(cap) 条）") }
        return out.joined(separator: "\n")
    }

    private static func makeDir(path rawPath: String, base: String) -> String {
        guard !rawPath.isEmpty else { return "缺少参数 path。" }
        let path = resolvePath(rawPath, base: base)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return "目录已存在：\(path)" }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return "创建目录失败：\(error.localizedDescription)"
        }
        return "已创建目录：\(path)"
    }

    private static func movePath(from rawFrom: String, to rawTo: String, base: String) -> String {
        guard !rawFrom.isEmpty, !rawTo.isEmpty else { return "缺少参数 from / to。" }
        let from = resolvePath(rawFrom, base: base)
        let to = resolvePath(rawTo, base: base)
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { return "源路径不存在：\(from)" }
        if fm.fileExists(atPath: to) { return "目标已存在，未移动：\(to)" }
        do {
            try fm.moveItem(atPath: from, toPath: to)
        } catch {
            return "移动失败：\(error.localizedDescription)"
        }
        return "已移动：\(from) -> \(to)"
    }

    private static func deletePath(path rawPath: String, recursive: Bool, base: String) -> String {
        guard !rawPath.isEmpty else { return "缺少参数 path。" }
        let path = resolvePath(rawPath, base: base)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return "路径不存在：\(path)" }
        if isDir.boolValue && !recursive {
            return "\(path) 是目录，递归删除需设置 recursive=true。"
        }
        do {
            try fm.removeItem(atPath: path)
        } catch {
            return "删除失败：\(error.localizedDescription)"
        }
        return "已删除：\(path)"
    }

    // MARK: - Git

    private static func gitDirectory(_ rawPath: String, base: String) -> String {
        rawPath.isEmpty ? base : resolvePath(rawPath, base: base)
    }

    private static func git(_ args: [String], path: String, settings: AppSettings, base: String) -> String {
        let dir = gitDirectory(path, base: base)
        guard FileManager.default.fileExists(atPath: dir) else { return "路径不存在：\(dir)" }
        let command = (["git", "-C", q(dir), "--no-pager"] + args.map(q)).joined(separator: " ")
        let (output, status, timedOut) = shellCapture(command, cwd: dir, timeout: Double(settings.commandTimeoutSeconds))
        let capped = capOutput(output, limit: settings.maxOutputChars)
        if timedOut { return "git 命令超时。\n\(capped)" }
        if capped.isEmpty { return status == 0 ? "（无输出）" : "git 退出码 \(status)" }
        return status == 0 ? capped : "git 退出码 \(status)：\n\(capped)"
    }

    private static func gitDiff(path: String, staged: Bool, settings: AppSettings, base: String) -> String {
        var args = ["diff", "--no-color"]
        if staged { args.append("--staged") }
        let result = git(args, path: path, settings: settings, base: base)
        return result
    }

    private static func gitLog(path: String, limit: Int?, settings: AppSettings, base: String) -> String {
        let count = min(max(limit ?? 20, 1), 500)
        return git(["log", "--oneline", "-n", "\(count)"], path: path, settings: settings, base: base)
    }

    private static func gitCommit(path: String, message: String, addAll: Bool,
                                  settings: AppSettings, base: String) -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "缺少提交信息 message。"
        }
        let dir = gitDirectory(path, base: base)
        guard FileManager.default.fileExists(atPath: dir) else { return "路径不存在：\(dir)" }
        var sections: [String] = []
        if addAll {
            let add = git(["add", "-A"], path: dir, settings: settings, base: base)
            if add.contains("git 退出码") { return "git add 失败：\n\(add)" }
            sections.append(add)
        }
        let commit = git(["commit", "-m", message], path: dir, settings: settings, base: base)
        sections.append(commit)
        return sections.filter { !$0.isEmpty && $0 != "（无输出）" }.joined(separator: "\n")
    }

    // MARK: - 命令执行

    private static func runCommand(command: String, cwd: String, timeoutSeconds: Int?,
                                   settings: AppSettings, base: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "缺少参数 command。" }
        let dir = cwd.isEmpty ? base : resolvePath(cwd, base: base)
        guard FileManager.default.fileExists(atPath: dir) else { return "工作目录不存在：\(dir)" }
        let timeout = min(max(Double(timeoutSeconds ?? settings.commandTimeoutSeconds), 1), 3600)
        let (output, status, timedOut) = shellCapture(command, cwd: dir, timeout: timeout)
        let limit = max(1000, settings.maxOutputChars)
        var body = capOutput(output, limit: limit)
        var header = "[cwd] \(dir)\n[exit] \(status)"
        if output.count > limit { header += "（输出已截断到 \(limit) 字符）" }
        if timedOut { header += "\n[超时] 命令超过 \(Int(timeout)) 秒被终止" }
        if body.isEmpty { body = "（无输出）" }
        return header + "\n" + body
    }

    // MARK: - 通用辅助

    /// 递归遍历基准目录下的普通文件；`handle` 返回 false 时提前停止。
    private static func walkFiles(base: String, handle: (String, String) -> Bool) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: base) else { return }
        for case let item as String in enumerator {
            let name = (item as NSString).lastPathComponent
            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let full = (base as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if !handle(item, full) { break }
        }
    }

    /// glob 匹配（`*`、`?`、`**`）。pattern 不含 `/` 时只匹配文件名。
    static func matchesGlob(pattern: String, path: String, caseSensitive: Bool = true) -> Bool {
        let target = pattern.contains("/") ? path : (path as NSString).lastPathComponent
        let regex = "^" + globToRegex(pattern) + "$"
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: regex, options: options) else { return false }
        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        return re.firstMatch(in: target, options: [], range: range) != nil
    }

    /// 把 glob 转换为正则片段。
    private static func globToRegex(_ pattern: String) -> String {
        var regex = ""
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        regex += "(?:.*/)?"
                        i += 3
                        continue
                    }
                    regex += ".*"
                    i += 2
                    continue
                }
                regex += "[^/]*"
            } else if c == "?" {
                regex += "[^/]"
            } else if ".+()[]{}^$|\\".contains(c) {
                regex += "\\" + String(c)
            } else {
                regex += String(c)
            }
            i += 1
        }
        return regex
    }

    /// 截断输出到 `limit` 个字符。
    private static func capOutput(_ text: String, limit: Int) -> String {
        let cap = max(1, limit)
        return text.count > cap ? String(text.prefix(cap)) : text
    }

    /// 执行 shell 命令，同时捕获 stdout 与 stderr，带超时。
    /// 返回 (合并输出, 退出码, 是否超时)。
    @discardableResult
    static func shellCapture(_ command: String, cwd: String?, timeout: TimeInterval) -> (String, Int32, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        do { try process.run() } catch {
            return ("执行失败：\(error.localizedDescription)", -1, false)
        }

        let flag = TimeoutFlag()
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            flag.set()
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(1, timeout), execute: watchdog)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text, process.terminationStatus, flag.value)
    }
}

/// 跨线程传递超时标记的小盒子。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    func set() {
        lock.lock(); flagged = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flagged
    }
}
