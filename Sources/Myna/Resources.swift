import Foundation

/// 提示词模板：`~/.config/myna/prompts/*.md`
struct PromptTemplate: Identifiable, Equatable {
    let id: String       // 文件名（不含扩展名）
    let title: String
    let body: String
}

/// 技能：`~/.config/myna/skills/<name>/SKILL.md`（支持 YAML frontmatter）
struct Skill: Identifiable, Equatable {
    let id: String       // 目录名
    let name: String
    let description: String
    let body: String
}

/// 本地插件：`~/.config/myna/plugins/<id>.json`。
///
/// 插件本身不复制文件，只把已有技能 / MCP 组合起来，并附带一段注入系统提示词的说明。
/// 这样 Myna 可以在运行时为自己创建「工具包」，下一次运行即生效。
struct LocalPlugin: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String = ""
    /// 启用时追加到系统提示词的说明（可写工作流、约束、偏好）。
    var instructions: String = ""
    /// 引用的技能 id。
    var skills: [String] = []
    /// 引用的 MCP 服务器 id。
    var mcps: [String] = []
    var enabled: Bool = true
}

/// 本地资源（提示词模板 / 技能 / 插件）的扫描与加载。
enum LocalResources {
    /// 配置目录。
    ///
    /// 跟随 `MYNA_CONFIG`：指向 `/tmp/x/config.json` 时，技能、插件、提示词、
    /// 备份与截图都会落在 `/tmp/x/`，自动化验证不会碰到用户真实数据。
    static var configDir: String {
        if let override = ProcessInfo.processInfo.environment["MYNA_CONFIG"], !override.isEmpty {
            let expanded = NSString(string: override).expandingTildeInPath
            let parent = (expanded as NSString).deletingLastPathComponent
            return parent.isEmpty ? FileManager.default.currentDirectoryPath : parent
        }
        return NSString(string: "~/.config/myna").expandingTildeInPath
    }
    static var promptsDir: String { configDir + "/prompts" }
    static var skillsDir: String { configDir + "/skills" }
    static var pluginsDir: String { configDir + "/plugins" }
    static var backupsDir: String { configDir + "/backups" }
    static var screenshotsDir: String { configDir + "/screenshots" }
    /// pi 智能体技能目录；与 Myna 目录格式相同（`<id>/SKILL.md`）。
    static var piSkillsDir: String { NSString(string: "~/.pi/agent/skills").expandingTildeInPath }

    /// 首次运行时创建目录并写入说明文件（不覆盖已有内容）。
    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: promptsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)

        let promptsReadme = promptsDir + "/README.md"
        if !fm.fileExists(atPath: promptsReadme) {
            let text = """
            # 提示词模板

            在此目录放置 `.md` 文件，Myna 会在输入框的「提示词」菜单里列出它们。
            点击即可把内容插入输入框（不会自动发送）。

            可选：首行写 `# 标题`，作为菜单里显示的名称；否则使用文件名。
            """
            try? text.write(toFile: promptsReadme, atomically: true, encoding: .utf8)
        }

        let skillsReadme = skillsDir + "/README.md"
        if !fm.fileExists(atPath: skillsReadme) {
            let text = """
            # 技能

            每个技能一个子目录，内含 `SKILL.md`：

            ```
            ~/.config/myna/skills/my-skill/SKILL.md
            ```

            `SKILL.md` 可带 frontmatter：

            ```
            ---
            name: 我的技能
            description: 一句话说明（会注入系统提示词）
            ---
            具体步骤……
            ```

            Myna 会把技能的 name/description 注入系统提示词，模型在需要时用
            `read_skill` 工具读取完整内容。

            此外，Myna 也会读取 `~/.pi/agent/skills/`（格式相同）；同 id 时以本目录为准。
            """
            try? text.write(toFile: skillsReadme, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 提示词模板

    static func prompts() -> [PromptTemplate] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: promptsDir) else { return [] }
        return names
            .filter { $0.hasSuffix(".md") && $0 != "README.md" }
            .sorted()
            .compactMap { file in
                let path = promptsDir + "/" + file
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                let id = String(file.dropLast(3))
                return PromptTemplate(id: id, title: title(of: text, fallback: id), body: text)
            }
    }

    private static func title(of text: String, fallback: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return fallback
    }

    // MARK: - 技能

    static func skills() -> [Skill] {
        var seen = Set<String>()
        var result: [Skill] = []
        // Myna 目录优先，pi 技能目录中同 id 的条目被忽略。
        for dir in [skillsDir, piSkillsDir] {
            for skill in skills(in: dir) where !seen.contains(skill.id) {
                seen.insert(skill.id)
                result.append(skill)
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    /// 扫描单个技能目录（`<id>/SKILL.md`）。
    private static func skills(in directory: String) -> [Skill] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return dirs.sorted().compactMap { dir in
            let path = directory + "/" + dir + "/SKILL.md"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let (meta, body) = parseFrontmatter(text)
            let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? dir
            let desc = meta["description"] ?? firstParagraph(body)
            return Skill(id: dir, name: name, description: desc, body: body)
        }
    }

    static func skill(named id: String) -> Skill? {
        skills().first { $0.id == id || $0.name == id }
    }

    // MARK: - 插件

    /// 读取全部本地插件（损坏的文件被忽略）。
    static func plugins() -> [LocalPlugin] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: pluginsDir) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { file in
                let path = pluginsDir + "/" + file
                guard let data = fm.contents(atPath: path),
                      let plugin = try? JSONDecoder().decode(LocalPlugin.self, from: data)
                else { return nil }
                return plugin
            }
    }

    static func plugin(id: String) -> LocalPlugin? {
        plugins().first { $0.id == id }
    }

    /// 简单 frontmatter 解析（仅支持 `key: value` 平铺）。
    static func parseFrontmatter(_ text: String) -> (meta: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], text) }
        var meta: [String: String] = [:]
        var idx = 1
        while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[idx]
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty { meta[key] = value }
            }
            idx += 1
        }
        let body = idx + 1 < lines.count ? lines[(idx + 1)...].joined(separator: "\n") : ""
        return (meta, body)
    }

    private static func firstParagraph(_ text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !t.hasPrefix("#") { return t }
        }
        return ""
    }

    // MARK: - 系统提示词注入

    /// 在基础系统提示词后追加编码模式说明、可用技能清单与已启用插件说明。
    ///
    /// `workingDirectory` 是会话解析后的工作目录；为空时回落应用默认。
    static func systemPrompt(base: String, codingMode: Bool = false,
                             workingDirectory: String? = nil) -> String {
        var prompt = base
        if codingMode {
            prompt += "\n\n" + codingAddendum(workingDirectory: ToolRunner.workingDirectory(workingDirectory))
        }
        let skills = skills()
        if !skills.isEmpty {
            let list = skills.map { "- \($0.name)（id: \($0.id)）：\($0.description)" }.joined(separator: "\n")
            prompt += "\n\n可用技能（需要时先用 read_skill 工具读取完整步骤再执行）：\n" + list
        }
        let activePlugins = plugins().filter(\.enabled)
        if !activePlugins.isEmpty {
            let sections = activePlugins.map { plugin -> String in
                var text = "### \(plugin.name)（id: \(plugin.id)）"
                if !plugin.description.isEmpty { text += "\n\(plugin.description)" }
                if !plugin.instructions.isEmpty { text += "\n" + plugin.instructions }
                return text
            }
            prompt += "\n\n已启用插件（遵循其中的工作流与约束）：\n" + sections.joined(separator: "\n\n")
        }
        return prompt
    }

    /// 编码模式附加提示词。
    static func codingAddendum(workingDirectory: String) -> String {
        """
        你现在处于编码模式，请以资深软件工程师的方式协助用户完成工程任务。
        工作目录：\(workingDirectory)（文件工具的默认相对路径基准）。
        规则：
        1. 动手前先查看代码与项目结构（list_dir / find_files / search_text / read_file / git_status），不要凭空臆造文件内容。
        2. 修改时优先使用精确的小改动（edit_file），避免无意义的大范围重写。
        3. 改动后运行相关的构建或测试（run_command）进行验证，并如实报告结果。
        4. 只在工作目录内操作，不要擅自改动无关文件。
        5. 完成后用简短中文总结：改了哪些文件、原因，以及如何验证。
        6. 涉及删除文件、提交历史等危险操作前，先向用户说明并获得确认。
        """
    }
}
