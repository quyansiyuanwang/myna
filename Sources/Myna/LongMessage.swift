import Foundation

/// 超长消息的折叠规则（与 UI 解耦，便于自检）。
///
/// 长文档气泡每帧都要重新排版（Markdown 解析 + 语法高亮 + 文本排版），
/// 一条上万字的消息就足以让整段会话在滚动或刷新时明显卡顿。
/// 这里把「多少字算长」「预览保留多少字」集中成纯逻辑，供界面与 `myna long-message-check` 共用。
enum LongMessage {
    /// 超过这个字数默认折叠。
    static let threshold = 3_000
    /// 折叠时保留的字数。
    static let previewLength = 1_500

    static func isLong(_ text: String) -> Bool {
        text.count > threshold
    }

    /// 折叠预览：尽量在换行处截断，并补省略号表明内容被截断。
    static func preview(of text: String) -> String {
        guard text.count > previewLength else { return text }
        let head = text.prefix(previewLength)
        if let cut = head.lastIndex(of: "\n"),
           head.distance(from: head.startIndex, to: cut) > previewLength / 2 {
            return String(head[..<cut]) + "\n\n…"
        }
        return String(head) + "…"
    }
}
