import Foundation

/// 把用户选中的文件/文件夹整理成提示词附件块。
///
/// 只读取用户显式选择的路径；文件夹只生成浅层清单，不递归读取内容。
enum AttachmentContext {
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "swift", "m", "mm", "h", "c", "cpp", "hpp",
        "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt",
        "json", "yaml", "yml", "toml", "xml", "html", "css", "scss",
        "sh", "zsh", "fish", "sql", "csv", "log", "ini", "conf", "plist",
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp",
    ]

    static func preamble(text: String, attachments: [Attachment], settings: AppSettings) -> String {
        guard !attachments.isEmpty else { return text }
        var lines: [String] = []
        lines.append("[附件]")
        lines.append("用户附加了以下本机文件/文件夹。需要完整内容时使用 read_file / list_dir；图片使用 view_image。")
        var inlineBudget = settings.attachmentInlineChars
        var inlineBlocks: [String] = []

        for attachment in attachments.prefix(max(1, settings.attachmentMaxItems)) {
            let path = NSString(string: attachment.path).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                lines.append("- \(attachment.name)：路径已失效（\(path)）")
                continue
            }
            if isDirectory.boolValue {
                let entries = directoryManifest(path)
                lines.append("- 文件夹：\(attachment.name)（\(path)，\(entries.count) 项）")
                for entry in entries.prefix(200) { lines.append("  - \(entry)") }
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            let ext = (path as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                lines.append("- 图片：\(attachment.name)（\(path)，\(byteText(size))）")
                continue
            }
            lines.append("- 文件：\(attachment.name)（\(path)，\(byteText(size))）")
            guard textExtensions.contains(ext), inlineBudget > 0, size <= 256 * 1024,
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let allowed = min(inlineBudget, 8_000, content.count)
            guard allowed > 0 else { continue }
            let snippet = String(content.prefix(allowed))
            inlineBlocks.append("<file path=\"\(path)\">\n\(snippet)\n</file>")
            inlineBudget -= allowed
        }

        if !inlineBlocks.isEmpty {
            lines.append("")
            lines.append("以下是小文本文件的前 \(settings.attachmentInlineChars) 字符内联内容：")
            lines.append(contentsOf: inlineBlocks)
        }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = lines.joined(separator: "\n")
        return head.isEmpty ? "请查看以下附件。\n\n\(block)" : "\(head)\n\n\(block)"
    }

    private static func directoryManifest(_ path: String) -> [String] {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var out: [String] = []
        for name in top.sorted().prefix(120) {
            let child = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                out.append("\(name)/")
                if let sub = try? fm.contentsOfDirectory(atPath: child) {
                    for subName in sub.sorted().prefix(20) { out.append("  \(name)/\(subName)") }
                }
            } else {
                out.append(name)
            }
        }
        return out
    }

    private static func byteText(_ bytes: Int64) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }
}
