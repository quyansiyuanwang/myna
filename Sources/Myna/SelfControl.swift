import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import Speech
import PiKit

/// 自我控制 API：让模型读写 Myna 自己的配置、权限与本地数据。
///
/// 所有写操作都先备份，再落盘，最后校验「写回后解码再编码」的值与请求一致；
/// 不一致就拒绝并保留原文件。技能 / 插件 / MCP 的变更会广播
/// ``Notification.Name/mynaResourcesChanged``，宿主据此重建下一次运行的 Agent。
enum SelfControlAPI {

    /// 本文件实现的工具名（供 `ToolRunner` 路由与设置界面分组）。
    static let toolNames: Set<String> = [
        "myna_settings", "myna_permissions", "myna_data",
        "skill_write", "skill_delete", "mcp_manage", "plugin_manage",
    ]

    // MARK: - 路径

    static var configPath: String {
        if let override = ProcessInfo.processInfo.environment["MYNA_CONFIG"], !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return NSString(string: "~/.config/myna/config.json").expandingTildeInPath
    }

    static var backupDir: String { LocalResources.backupsDir }
    static var screenshotsDir: String { LocalResources.screenshotsDir }
    static var pluginsDir: String { LocalResources.pluginsDir }

    // MARK: - 工具入口

    /// 执行一个自我控制工具。参数与 `ToolRunner.definitions` 中的 schema 对应。
    static func run(_ name: String, args: [String: Any]) -> String {
        // 触发 SettingsStore 初始化（含视觉能力等旧配置迁移），保证 API
        // 在 CLI 与 App 下看到同一份配置。
        _ = SettingsStore.shared
        func str(_ key: String) -> String { args[key] as? String ?? "" }
        func bool(_ key: String, _ fallback: Bool) -> Bool { args[key] as? Bool ?? fallback }
        func strings(_ key: String) -> [String] { args[key] as? [String] ?? [] }
        do {
            switch name {
            case "myna_settings":
                return try settingsAction(str("action"), args: args)
            case "myna_permissions":
                return try permissionsAction(str("action"), which: str("which"))
            case "myna_data":
                return try dataAction(str("action"), args: args)
            case "skill_write":
                return try skillWrite(id: str("id"), name: str("name"),
                                      description: str("description"),
                                      body: str("body"),
                                      overwrite: bool("overwrite", true))
            case "skill_delete":
                return try skillDelete(id: str("id"))
            case "mcp_manage":
                return try mcpAction(str("action"), args: args)
            case "plugin_manage":
                return try pluginAction(str("action"), args: args)
            default:
                return "未知的自我控制工具：\(name)"
            }
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 配置读写

    static func settingsAction(_ action: String, args: [String: Any]) throws -> String {
        switch action {
        case "keys":
            return try allowedKeys().sorted().joined(separator: "\n")
        case "get":
            let key = args["key"] as? String ?? ""
            let reveal = args["reveal"] as? Bool ?? false
            let object = try currentConfig()
            if key.isEmpty {
                var copy = object
                if !reveal { maskSecrets(&copy) }
                return try jsonText(copy)
            }
            guard let value = object[key] else { throw SelfControlError.unknownKey(key) }
            return try jsonText(value)
        case "set":
            guard let key = args["key"] as? String, !key.isEmpty else {
                throw SelfControlError.message("缺少 key")
            }
            let rawValue: Any = args["value"] ?? NSNull()
            let value: Any
            if let text = rawValue as? String {
                value = try parseJSON(text)
            } else {
                value = rawValue
            }
            let backup = args["backup"] as? Bool ?? true
            return try setSetting(key: key, value: value, backup: backup)
        case "backup":
            guard let path = backupConfig() else {
                throw SelfControlError.message("没有可备份的配置文件")
            }
            return "已备份到 \(path)"
        case "restore":
            let name = args["name"] as? String ?? ""
            return try restoreSetting(name: name)
        case "backups":
            return backupFiles().joined(separator: "\n")
        default:
            throw SelfControlError.message("未知动作「\(action)」，应为 get / set / keys / backup / restore / backups")
        }
    }

    /// 当前配置文件内容；文件不存在时用默认设置编码生成。
    private static func currentConfig() throws -> [String: Any] {
        let fm = FileManager.default
        if let data = fm.contents(atPath: configPath) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SelfControlError.message("配置文件不是合法的 JSON 对象：\(configPath)")
            }
            return object
        }
        let data = try JSONEncoder().encode(AppSettings())
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// 所有允许的键：默认设置编码出的键 + 当前文件里已有的键（兼容旧键）。
    static func allowedKeys() throws -> Set<String> {
        var keys = Set(try currentConfig().keys)
        let defaults = try JSONEncoder().encode(AppSettings())
        if let object = try JSONSerialization.jsonObject(with: defaults) as? [String: Any] {
            keys.formUnion(object.keys)
        }
        return keys
    }

    /// 写入一个配置键。先 flush 主线程的待写改动，再备份、写盘、校验、通知重载。
    static func setSetting(key: String, value: Any, backup: Bool) throws -> String {
        // 设置界面可能还有 0.4s 防抖的未落盘改动，先刷下去，避免被本次写入覆盖。
        flushPendingSettings()
        let allowed = try allowedKeys()
        guard allowed.contains(key) else {
            throw SelfControlError.unknownKey(key)
        }
        var object = try currentConfig()
        let old = object[key]
        object[key] = value

        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        // 解码 + 重新编码，确认请求的值真的被这个配置结构接受。
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let verified = try encodedObject(decoded)
        let expected = normalizedJSON(value)
        let actual = normalizedJSON(verified[key])
        guard jsonEqual(expected, actual) else {
            throw SelfControlError.message("值 \(try jsonText(value)) 无法写入 \(key)（类型或结构不匹配），已拒绝")
        }

        if backup { _ = backupConfig() }
        try write0600(data, to: configPath)
        notifyResourcesChanged()
        reloadSettingsOnMain()
        let display = try jsonText(value)
        return "已设置 \(key) = \(display)（旧值：\(old.map { (try? jsonText($0)) ?? "?" } ?? "无")）"
    }

    /// 恢复备份；`name` 为空时使用最近的一份。
    static func restoreSetting(name: String) throws -> String {
        let files = backupFiles()
        guard let chosen = name.isEmpty ? files.first : files.first(where: { ($0 as NSString).lastPathComponent == name || $0 == name }) else {
            throw SelfControlError.message("没有找到备份：\(name.isEmpty ? "（空）" : name)")
        }
        guard let data = FileManager.default.contents(atPath: chosen) else {
            throw SelfControlError.message("备份不可读：\(chosen)")
        }
        // 先验证是一份可解码的完整配置，再覆盖。
        _ = try JSONDecoder().decode(AppSettings.self, from: data)
        _ = backupConfig()
        try write0600(data, to: configPath)
        notifyResourcesChanged()
        reloadSettingsOnMain()
        return "已从 \(chosen) 恢复配置"
    }

    static func backupConfig() -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else { return nil }
        try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let stamp = SelfControlAPI.stamp()
        let target = backupDir + "/config-\(stamp).json"
        guard let data = fm.contents(atPath: configPath) else { return nil }
        do {
            try write0600(data, to: target)
        } catch {
            return nil
        }
        pruneBackups()
        return target
    }

    /// 备份文件（新的在前）。
    static func backupFiles() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backupDir) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted(by: >)
            .map { backupDir + "/" + $0 }
    }

    private static func pruneBackups(keep: Int = 50) {
        let files = backupFiles()
        guard files.count > keep else { return }
        for path in files.dropFirst(keep) { try? FileManager.default.removeItem(atPath: path) }
    }

    /// 在主线程刷新 `SettingsStore`（配置文件已由本 API 写入）。
    ///
    /// 用「有界等待」而不是 `main.sync`：CLI 的 `agent` 会在主线程上等待任务
    /// 完成，`main.sync` 会死锁。应用运行时主线程空闲，1 秒足够完成刷新；
    /// 超时则保留已排队的刷新块，稍后执行（文件已经正确）。
    private static func reloadSettingsOnMain() {
        if Thread.isMainThread {
            SettingsStore.shared.reloadFromDisk()
            return
        }
        _ = runOnMainWithTimeout(1.0) { SettingsStore.shared.reloadFromDisk() }
    }

    /// 在后台线程有界地等待主线程执行一段同步操作。
    @discardableResult
    private static func runOnMainWithTimeout(_ seconds: TimeInterval,
                                             _ body: @escaping @Sendable () -> Void) -> Bool {
        if Thread.isMainThread {
            body()
            return true
        }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            body()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + seconds) == .success
    }

    /// 把设置界面尚未落盘的防抖改动刷到磁盘，避免覆盖用户刚做的修改。
    ///
    /// 主线程忙（例如 CLI 阻塞等待）时取消这次 flush，否则排队中的 flush
    /// 可能在本次写入之后才执行，用旧快照覆盖新值。
    private static func flushPendingSettings() {
        if Thread.isMainThread {
            SettingsStore.shared.flush()
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        let item = DispatchWorkItem {
            SettingsStore.shared.flush()
            semaphore.signal()
        }
        DispatchQueue.main.async(execute: item)
        if semaphore.wait(timeout: .now() + 1.0) != .success {
            item.cancel()
        }
    }

    // MARK: - 权限

    struct PermissionEntry {
        let id: String
        let name: String
        let state: String
        let pane: String
    }

    static func permissionEntries() -> [PermissionEntry] {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "已授权"
        case .denied: mic = "已拒绝"
        case .restricted: mic = "受限"
        case .notDetermined: mic = "未询问"
        @unknown default: mic = "未知"
        }
        let speech: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = "已授权"
        case .denied: speech = "已拒绝"
        case .restricted: speech = "受限"
        case .notDetermined: speech = "未询问"
        @unknown default: speech = "未知"
        }
        return [
            .init(id: "accessibility", name: "辅助功能（鼠标 / 键盘控制）",
                  state: AXIsProcessTrusted() ? "已授权" : "未授权", pane: "Privacy_Accessibility"),
            .init(id: "screen", name: "屏幕录制（截图 / OCR）",
                  state: CGPreflightScreenCaptureAccess() ? "已授权" : "未授权", pane: "Privacy_ScreenCapture"),
            .init(id: "microphone", name: "麦克风", state: mic, pane: "Privacy_Microphone"),
            .init(id: "speech", name: "语音识别", state: speech, pane: "Privacy_SpeechRecognition"),
            .init(id: "automation", name: "自动化（AppleScript / 系统事件）",
                  state: "无法查询（首次调用时系统询问）", pane: "Privacy_Automation"),
        ]
    }

    static func permissionsAction(_ action: String, which: String) throws -> String {
        switch action {
        case "status":
            let lines = permissionEntries().map { entry in
                "\(entry.id)  \(entry.name)：\(entry.state)"
            }
            return lines.joined(separator: "\n")
        case "open":
            let entries = permissionEntries()
            guard let entry = entries.first(where: { $0.id == which }) else {
                throw SelfControlError.message("未知权限「\(which)」，可选：\(entries.map(\.id).joined(separator: "、"))")
            }
            openPane(entry.pane)
            return "已打开系统设置：\(entry.name)"
        case "request":
            return try requestPermission(which)
        default:
            throw SelfControlError.message("未知动作「\(action)」，应为 status / open / request")
        }
    }

    private static func requestPermission(_ which: String) throws -> String {
        switch which {
        case "accessibility":
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPane("Privacy_Accessibility")
            return "已请求辅助功能权限；若未出现弹窗，请在系统设置中手动勾选 Myna。授权后需重启 Myna。"
        case "screen":
            if CGPreflightScreenCaptureAccess() { return "屏幕录制权限已授权。" }
            _ = CGRequestScreenCaptureAccess()
            openPane("Privacy_ScreenCapture")
            return "已请求屏幕录制权限；授权后需重启 Myna 才能截图。"
        case "microphone":
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return "已请求麦克风权限（系统弹窗）。"
        case "speech":
            SFSpeechRecognizer.requestAuthorization { _ in }
            return "已请求语音识别权限（系统弹窗）。"
        case "automation":
            openPane("Privacy_Automation")
            return "已打开自动化权限页；首次运行 AppleScript 时系统也会询问。"
        default:
            throw SelfControlError.message("未知权限「\(which)」")
        }
    }

    private static func openPane(_ pane: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        DispatchQueue.main.async {
            _ = ToolRunner.sh("open \(ToolRunner.q(url))")
        }
    }

    // MARK: - 数据

    /// 数据位置清单：名称、路径、存在与否、大小。
    static func dataInventory() -> [(name: String, path: String, exists: Bool, size: Int)] {
        let fm = FileManager.default
        let conversations = ProcessInfo.processInfo.environment["MYNA_CONVERSATIONS"]
            ?? LocalResources.configDir + "/conversations.json"
        let items: [(String, String)] = [
            ("config", configPath),
            ("conversations", conversations),
            ("skills", LocalResources.skillsDir),
            ("plugins", pluginsDir),
            ("prompts", LocalResources.promptsDir),
            ("profiles", SettingsStore.profilesDirectory),
            ("mcp", MCPManager.configPath),
            ("screenshots", screenshotsDir),
            ("backups", backupDir),
            ("stall_log", LocalResources.configDir + "/stall.log"),
            ("safe_mode", LocalResources.configDir + "/safe-mode.json"),
        ]
        return items.map { name, path in
            let exists = fm.fileExists(atPath: path)
            return (name, path, exists, exists ? directorySize(path) : 0)
        }
    }

    static func dataAction(_ action: String, args: [String: Any]) throws -> String {
        switch action {
        case "list":
            return dataInventory().map { item in
                let state = item.exists ? "\(humanSize(item.size))" : "不存在"
                return "\(item.name)\t\(state)\t\(item.path)"
            }.joined(separator: "\n")
        case "read":
            let target = args["target"] as? String ?? "config"
            let limit = args["limit"] as? Int ?? 20_000
            guard let item = dataInventory().first(where: { $0.name == target }) else {
                throw SelfControlError.message("未知数据目标「\(target)」，可选：\(dataInventory().map(\.name).joined(separator: "、"))")
            }
            let fm = FileManager.default
            let attrs = try? fm.attributesOfItem(atPath: item.path)
            if (attrs?[.type] as? FileAttributeType) == .typeDirectory {
                // 目录：列出条目（不递归）
                let names = (try? fm.contentsOfDirectory(atPath: item.path)) ?? []
                return "目录 \(item.path)：\n" + names.sorted().joined(separator: "\n")
            }
            guard let data = fm.contents(atPath: item.path) else {
                throw SelfControlError.message("文件不存在或不可读：\(item.path)")
            }
            let text = String(data: data, encoding: .utf8) ?? "（非 UTF-8 数据，\(data.count) 字节）"
            return "# \(item.path)\n" + String(text.prefix(max(limit, 100)))
        case "export":
            let fm = FileManager.default
            let target = args["path"] as? String ?? (LocalResources.configDir + "/Myna-backup-\(stamp()).zip")
            let path = NSString(string: target).expandingTildeInPath
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            let result = ToolRunner.sh("ditto -c -k --sequesterRsrc --keepParent \(ToolRunner.q(LocalResources.configDir)) \(ToolRunner.q(path))", timeout: 120)
            guard fm.fileExists(atPath: path) else {
                throw SelfControlError.message("导出失败：\(result)")
            }
            return "已导出到 \(path)（\(humanSize(directorySize(path)))）"
        case "delete":
            let target = args["target"] as? String ?? ""
            let id = args["id"] as? String ?? ""
            return try deleteData(target: target, id: id)
        default:
            throw SelfControlError.message("未知动作「\(action)」，应为 list / read / export / delete")
        }
    }

    private static func deleteData(target: String, id: String) throws -> String {
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else {
            throw SelfControlError.message("delete 需要安全的 id（不能包含 / 或 ..）")
        }
        let fm = FileManager.default
        switch target {
        case "skill":
            let dir = LocalResources.skillsDir + "/" + id
            guard fm.fileExists(atPath: dir) else { throw SelfControlError.message("技能不存在：\(id)") }
            try backupFile(LocalResources.skillsDir + "/" + id + "/SKILL.md", label: "skill-\(id)")
            try fm.removeItem(atPath: dir)
            notifyResourcesChanged()
            return "已删除技能 \(id)（原文件已备份）"
        case "plugin":
            let path = pluginsDir + "/" + id + ".json"
            guard fm.fileExists(atPath: path) else { throw SelfControlError.message("插件不存在：\(id)") }
            try backupFile(path, label: "plugin-\(id)")
            try fm.removeItem(atPath: path)
            notifyResourcesChanged()
            return "已删除插件 \(id)"
        case "profile":
            let path = SettingsStore.profilesDirectory + "/" + id + ".json"
            guard fm.fileExists(atPath: path) else { throw SelfControlError.message("配置方案不存在：\(id)") }
            try backupFile(path, label: "profile-\(id)")
            try fm.removeItem(atPath: path)
            return "已删除配置方案 \(id)"
        case "prompt":
            let file = id.hasSuffix(".md") ? id : id + ".md"
            let path = LocalResources.promptsDir + "/" + file
            guard fm.fileExists(atPath: path) else { throw SelfControlError.message("提示词不存在：\(file)") }
            try backupFile(path, label: "prompt-\(id)")
            try fm.removeItem(atPath: path)
            return "已删除提示词 \(file)"
        case "mcp":
            guard MCPManager.shared.removeServer(name: id) else {
                throw SelfControlError.message("MCP 服务器不存在：\(id)")
            }
            MCPManager.shared.reload()
            return "已删除 MCP 服务器 \(id)"
        case "screenshot":
            let path = screenshotsDir + "/" + id
            guard fm.fileExists(atPath: path) else { throw SelfControlError.message("截图不存在：\(id)") }
            try fm.removeItem(atPath: path)
            return "已删除截图 \(id)"
        default:
            throw SelfControlError.message("未知目标「\(target)」，应为 skill / plugin / profile / prompt / mcp / screenshot")
        }
    }

    // MARK: - 技能

    static func sanitizedID(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var result = ""
        for scalar in raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if allowed.contains(scalar) { result.unicodeScalars.append(scalar) }
            else if scalar == " " { result.append("-") }
        }
        return result.isEmpty ? "" : String(result.prefix(64))
    }

    static func skillWrite(id rawID: String, name: String, description: String,
                           body: String, overwrite: Bool) throws -> String {
        let id = sanitizedID(rawID)
        guard !id.isEmpty else { throw SelfControlError.message("技能 id 不能为空（仅允许字母、数字、._-）") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelfControlError.message("技能正文不能为空")
        }
        let dir = LocalResources.skillsDir + "/" + id
        let path = dir + "/SKILL.md"
        let fm = FileManager.default
        if fm.fileExists(atPath: path), !overwrite {
            throw SelfControlError.message("技能 \(id) 已存在；需要覆盖请传 overwrite=true")
        }
        if fm.fileExists(atPath: path) {
            try backupFile(path, label: "skill-\(id)")
        }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let title = name.isEmpty ? id : name
        let text = """
        ---
        name: \(yamlScalar(title))
        description: \(yamlScalar(description))
        ---
        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        try write0600(Data(text.utf8), to: path)
        notifyResourcesChanged()
        return "已写入技能 \(id) → \(path)；下一次运行会自动出现在系统提示词的技能清单里。"
    }

    static func skillDelete(id: String) throws -> String {
        let safe = sanitizedID(id)
        guard !safe.isEmpty else { throw SelfControlError.message("技能 id 无效") }
        return try deleteData(target: "skill", id: safe)
    }

    // MARK: - 插件

    static func pluginAction(_ action: String, args: [String: Any]) throws -> String {
        switch action {
        case "list":
            let plugins = LocalResources.plugins()
            if plugins.isEmpty { return "（没有本地插件）" }
            return plugins.map { plugin in
                let state = plugin.enabled ? "启用" : "停用"
                return "\(plugin.id)\t\(state)\t\(plugin.name)\t技能 \(plugin.skills.count) / MCP \(plugin.mcps.count)"
            }.joined(separator: "\n")
        case "create":
            let id = sanitizedID(args["id"] as? String ?? "")
            guard !id.isEmpty else { throw SelfControlError.message("插件 id 无效") }
            let name = (args["name"] as? String ?? "").isEmpty ? id : (args["name"] as! String)
            let plugin = LocalPlugin(
                id: id,
                name: name,
                description: args["description"] as? String ?? "",
                instructions: args["instructions"] as? String ?? "",
                skills: (args["skills"] as? [String] ?? []).map(sanitizedID).filter { !$0.isEmpty },
                mcps: args["mcps"] as? [String] ?? [],
                enabled: true
            )
            var warnings: [String] = []
            let installedSkills = Set(LocalResources.skills().map(\.id))
            for skill in plugin.skills where !installedSkills.contains(skill) {
                warnings.append("技能 \(skill) 尚未安装（插件仍已保存）")
            }
            let configuredMCP = Set(MCPManager.shared.configuredServers().map(\.name))
            for mcp in plugin.mcps where !configuredMCP.contains(mcp) {
                warnings.append("MCP \(mcp) 尚未配置（插件仍已保存）")
            }
            try writePlugin(plugin)
            notifyResourcesChanged()
            return "已保存插件 \(id)"
                + (warnings.isEmpty ? "" : "\n注意：" + warnings.joined(separator: "；"))
        case "enable", "disable":
            let id = args["id"] as? String ?? ""
            guard var plugin = LocalResources.plugin(id: id) else {
                throw SelfControlError.message("插件不存在：\(id)")
            }
            plugin.enabled = (action == "enable")
            try writePlugin(plugin)
            notifyResourcesChanged()
            return "已\(plugin.enabled ? "启用" : "停用")插件 \(id)"
        case "delete":
            return try deleteData(target: "plugin", id: args["id"] as? String ?? "")
        default:
            throw SelfControlError.message("未知动作「\(action)」，应为 list / create / enable / disable / delete")
        }
    }

    static func writePlugin(_ plugin: LocalPlugin) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        let path = pluginsDir + "/" + plugin.id + ".json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plugin)
        try write0600(data, to: path)
    }

    // MARK: - MCP

    static func mcpAction(_ action: String, args: [String: Any]) throws -> String {
        switch action {
        case "list":
            let servers = MCPManager.shared.configuredServers()
            if servers.isEmpty { return "（没有配置 MCP 服务器）" }
            let tools = MCPManager.shared.tools()
            return servers.map { server in
                let names = tools.filter { $0.name.hasPrefix("mcp__\(MCPManager.sanitize(server.name))__") }
                let suffix = names.isEmpty ? "未加载工具" : "工具：" + names.map(\.name).joined(separator: "、")
                return "\(server.name)\t\(server.config.command)\t\(suffix)"
            }.joined(separator: "\n")
        case "add":
            let id = args["id"] as? String ?? ""
            guard !id.isEmpty else { throw SelfControlError.message("缺少 id") }
            let command = args["command"] as? String ?? ""
            guard !command.isEmpty else { throw SelfControlError.message("缺少 command") }
            let config = MCPServerConfig(command: command,
                                         args: args["args"] as? [String],
                                         env: args["env"] as? [String: String])
            guard MCPManager.shared.upsertServer(name: id, config: config) else {
                throw SelfControlError.message("写入 mcp.json 失败")
            }
            MCPManager.shared.reload()
            notifyResourcesChanged(delayed: true)
            return "已添加 MCP 服务器 \(id)（\(command)）；已触发热重载，新工具加载后下一次运行可用。"
        case "remove":
            let id = args["id"] as? String ?? ""
            guard MCPManager.shared.removeServer(name: id) else {
                throw SelfControlError.message("MCP 服务器不存在：\(id)")
            }
            MCPManager.shared.reload()
            notifyResourcesChanged(delayed: true)
            return "已删除 MCP 服务器 \(id)"
        case "reload":
            MCPManager.shared.reload()
            notifyResourcesChanged(delayed: true)
            return "已触发 MCP 重载"
        case "call":
            let server = args["id"] as? String ?? (args["server"] as? String ?? "")
            let tool = args["tool"] as? String ?? ""
            guard !server.isEmpty, !tool.isEmpty else {
                throw SelfControlError.message("call 需要 id（服务器）与 tool")
            }
            let raw = args["arguments"] as? String ?? "{}"
            let value = try parseJSON(raw)
            let json: JSONValue
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                json = parsed
            } else {
                json = .object([:])
            }
            let namespaced = "mcp__\(MCPManager.sanitize(server))__\(MCPManager.sanitize(tool))"
            return MCPManager.shared.callSync(namespaced: namespaced, arguments: json)
        default:
            throw SelfControlError.message("未知动作「\(action)」，应为 list / add / remove / reload / call")
        }
    }

    // MARK: - 广播

    static func notifyResourcesChanged(delayed: Bool = false) {
        let post = {
            NotificationCenter.default.post(name: .mynaResourcesChanged, object: nil)
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
        guard delayed else { return }
        // MCP 启动是异步的：稍后再广播一次，让新工具名单进入下一次 Agent 构建。
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(name: .mynaResourcesChanged, object: nil)
            }
        }
    }

    // MARK: - 底层

    private static func write0600(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static func backupFile(_ path: String, label: String) throws {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: path) else { return }
        try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let target = backupDir + "/\(label)-\(stamp()).bak"
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
    }

    private static func encodedObject(_ settings: AppSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func normalizedJSON(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let dict = value as? [String: Any] {
            return dict.mapValues { normalizedJSON($0) }
        }
        if let array = value as? [Any] {
            return array.map { normalizedJSON($0) }
        }
        return value
    }

    private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let a as NSObject, let b as NSObject): return a.isEqual(b)
        default: return false
        }
    }

    /// 设置里的密钥字段在整份导出时默认打码；按键查询时仍可显式读取。
    private static func maskSecrets(_ object: inout [String: Any]) {
        let secretKeys = ["api_key", "search_api_key", "proxy_password"]
        for key in secretKeys {
            if let value = object[key] as? String, !value.isEmpty {
                object[key] = String(value.prefix(4)) + "…（已隐藏，读取请传 reveal=true）"
            }
        }
        if let providers = object["providers"] as? [[String: Any]] {
            object["providers"] = providers.map { provider -> [String: Any] in
                var copy = provider
                if let value = copy["api_key"] as? String, !value.isEmpty {
                    copy["api_key"] = String(value.prefix(4)) + "…（已隐藏）"
                }
                return copy
            }
        }
    }

    static func parseJSON(_ raw: String) throws -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return NSNull() }
        guard let data = trimmed.data(using: .utf8) else {
            throw SelfControlError.message("无法编码字符串")
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            // 不是 JSON：按普通字符串处理（方便设置提示词、路径等）。
            return trimmed
        }
    }

    static func jsonText(_ value: Any) throws -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 {
                return String(Int(double))
            }
            return String(double)
        }
        guard JSONSerialization.isValidJSONObject(value) else {
            return String(describing: value)
        }
        let data = try JSONSerialization.data(withJSONObject: value,
                                              options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? String(describing: value)
    }

    private static func yamlScalar(_ raw: String) -> String {
        let single = raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        return "\"\(single)\""
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    private static func directorySize(_ path: String) -> Int {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return 0 }
        if (attrs[.type] as? FileAttributeType) == .typeRegular {
            return (attrs[.size] as? NSNumber)?.intValue ?? 0
        }
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let file as String in enumerator {
            if let size = (try? fm.attributesOfItem(atPath: path + "/" + file))?[.size] as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    static func humanSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

enum SelfControlError: Error, LocalizedError {
    case unknownKey(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unknownKey(let key): return "未知配置键「\(key)」"
        case .message(let text): return text
        }
    }
}

extension Notification.Name {
    /// 技能 / 插件 / MCP / 配置发生变化；宿主应让下一次运行重建 Agent。
    static let mynaResourcesChanged = Notification.Name("MynaResourcesChanged")
}
