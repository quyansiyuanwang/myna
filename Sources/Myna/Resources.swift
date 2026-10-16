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

/// 本地资源（提示词模板 / 技能）的扫描与加载。
enum LocalResources {
    static var configDir: String { NSString(string: "~/.config/myna").expandingTildeInPath }
    static var promptsDir: String { configDir + "/prompts" }
    static var skillsDir: String { configDir + "/skills" }

    /// 首次运行时创建目录并写入说明文件（不覆盖已有内容）。
    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: promptsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)

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
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: skillsDir) else { return [] }
        return dirs.sorted().compactMap { dir in
            let path = skillsDir + "/" + dir + "/SKILL.md"
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

    /// 在基础系统提示词后追加可用技能清单。
    static func systemPrompt(base: String) -> String {
        let skills = skills()
        guard !skills.isEmpty else { return base }
        let list = skills.map { "- \($0.name)（id: \($0.id)）：\($0.description)" }.joined(separator: "\n")
        return base + "\n\n可用技能（需要时先用 read_skill 工具读取完整步骤再执行）：\n" + list
    }
}
