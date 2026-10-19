import SwiftUI

// MARK: - 内联样式

/// 内联 Markdown 的语义样式。
///
/// 解析与排版分开：``MarkdownInline/spans(_:)`` 只负责把 Markdown 解析成
/// 「文本 + 语义样式」，``MarkdownInline/spec(for:size:weight:)`` 再换算成具体字号 /
/// 字重 / 颜色语义。`myna markdown-check` 校验的正是这两步，因此它们不依赖 SwiftUI 渲染。
enum MarkdownInlineStyle: String, Hashable, CaseIterable {
    case strong
    case emphasis
    case code
    case strikethrough
    case link
}

/// 前景色语义（具体颜色由渲染层按明暗外观取值）。
enum MarkdownForeground: Equatable {
    case base
    case secondary
    case accent
}

/// 一段内联文本的最终排版参数。
struct MarkdownInlineSpec: Equatable {
    var size: CGFloat
    var weight: Font.Weight
    var italic: Bool = false
    var monospaced: Bool = false
    var foreground: MarkdownForeground = .base
    var background: Bool = false
    var strikethrough: Bool = false
    var underline: Bool = false
}

/// 一段带语义样式的内联文本。
struct MarkdownSpan: Equatable {
    var text: String
    var styles: Set<MarkdownInlineStyle>

    func has(_ style: MarkdownInlineStyle) -> Bool { styles.contains(style) }
}

enum MarkdownInline {
    /// 把行内 Markdown 解析成「文本 + 语义样式」序列；解析失败时退回纯文本。
    static func spans(_ s: String) -> [MarkdownSpan] {
        guard !s.isEmpty else { return [] }
        guard let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return [MarkdownSpan(text: s, styles: [])]
        }
        var out: [MarkdownSpan] = []
        for run in attr.runs {
            var styles: Set<MarkdownInlineStyle> = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { styles.insert(.strong) }
                if intent.contains(.emphasized) { styles.insert(.emphasis) }
                if intent.contains(.code) { styles.insert(.code) }
                if intent.contains(.strikethrough) { styles.insert(.strikethrough) }
            }
            if run.link != nil { styles.insert(.link) }
            out.append(MarkdownSpan(text: String(attr[run.range].characters), styles: styles))
        }
        return out.isEmpty ? [MarkdownSpan(text: s, styles: [])] : out
    }

    /// 由语义样式换算排版参数。
    ///
    /// - `strong`: 正文字号、粗体
    /// - `emphasis`: 正文字号、斜体
    /// - `code`: 字号 -1、等宽、浅底色、强调色前景
    /// - `strikethrough`: 单实线删除线、次级前景
    /// - `link`: 强调色前景 + 下划线
    static func spec(for styles: Set<MarkdownInlineStyle>,
                     size: CGFloat,
                     weight: Font.Weight) -> MarkdownInlineSpec {
        var spec = MarkdownInlineSpec(size: size, weight: weight)
        if styles.contains(.code) {
            // 行内代码优先：等宽 + 底色，不再叠加斜体，避免等宽斜体难以辨认。
            spec.size = max(10, size - 1)
            spec.monospaced = true
            spec.italic = false
            spec.weight = styles.contains(.strong) ? .semibold : weight
            spec.foreground = .accent
            spec.background = true
        } else {
            if styles.contains(.emphasis) { spec.italic = true }
            if styles.contains(.strong) { spec.weight = .bold }
        }
        if styles.contains(.strikethrough) {
            spec.strikethrough = true
            if spec.foreground == .base { spec.foreground = .secondary }
        }
        if styles.contains(.link) {
            spec.foreground = .accent
            spec.underline = true
        }
        return spec
    }

    /// 生成**显式属性**的富文本。
    ///
    /// 关键点：不依赖 `Text` 去解释 `inlinePresentationIntent`（它对 `code` /
    /// `strikethrough` 不生效），而是先把运行段收集出来，再逐段写入
    /// `font` / `foregroundColor` / `backgroundColor` / `strikethroughStyle` /
    /// `underlineStyle`。`.base` 前景不写属性，保留外层 `foregroundColor` 的继承
    /// （工具区块、错误气泡都依赖这一点）。
    static func attributed(_ s: String,
                           size: CGFloat,
                           weight: Font.Weight = .regular,
                           accent: Color,
                           dark: Bool = false,
                           baseColor: Color? = nil) -> AttributedString {
        var out = AttributedString()
        for span in spans(s) {
            let spec = spec(for: span.styles, size: size, weight: weight)
            var piece = AttributedString(span.text)
            piece.font = font(for: spec)
            switch spec.foreground {
            case .base:
                // 正文默认不写前景色，保留外层 `foregroundColor` 的继承；
                // 引用块等需要次级色时由调用方显式传入。
                if let baseColor { piece.foregroundColor = baseColor }
            case .secondary:
                piece.foregroundColor = Color(nsColor: .secondaryLabelColor)
            case .accent:
                piece.foregroundColor = spec.monospaced ? codeColor(accent, dark: dark) : accent
            }
            if spec.background {
                piece.backgroundColor = Color.primary.opacity(0.08)
            }
            if spec.strikethrough {
                piece.strikethroughStyle = .single
            }
            if spec.underline {
                piece.underlineStyle = .single
            }
            out.append(piece)
        }
        return out
    }

    /// 由排版参数构造字体。
    static func font(for spec: MarkdownInlineSpec) -> Font {
        var font: Font = spec.monospaced
            ? .system(size: spec.size, weight: spec.weight, design: .monospaced)
            : .system(size: spec.size, weight: spec.weight)
        if spec.italic { font = font.italic() }
        return font
    }

    /// 行内代码前景：强调色向正文色靠拢，保证明暗两种外观下对比度都够。
    static func codeColor(_ accent: Color, dark: Bool) -> Color {
        let fraction: CGFloat = dark ? 0.50 : 0.40
        let target: NSColor = dark ? .white : .black
        if let mixed = NSColor(accent).blended(withFraction: fraction, of: target) {
            return Color(nsColor: mixed)
        }
        return accent
    }
}

// MARK: - 块级模型

/// Markdown 表格（已按列拆分并 trim）。
struct MarkdownTable: Equatable {
    var header: [String]
    var rows: [[String]]

    /// 每列宽度（宽字符按 2 个等宽字符计），并按最宽的单元格补齐空格。
    ///
    /// 用等宽字体渲染后各列即可对齐；返回的每一行长度都相同。
    func paddedLines() -> (header: String, rows: [String]) {
        var table = self
        let columns = max(1, max(header.count, rows.map(\.count).max() ?? 0))
        while table.header.count < columns { table.header.append("") }
        for i in table.rows.indices {
            while table.rows[i].count < columns { table.rows[i].append("") }
        }
        var widths = [Int](repeating: 0, count: columns)
        for (c, cell) in table.header.enumerated() {
            widths[c] = max(widths[c], MarkdownTable.displayWidth(cell))
        }
        for row in table.rows {
            for (c, cell) in row.enumerated() where c < columns {
                widths[c] = max(widths[c], MarkdownTable.displayWidth(cell))
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { c, cell in
                cell + String(repeating: " ", count: max(0, widths[c] - MarkdownTable.displayWidth(cell)))
            }.joined(separator: "  ")
        }
        return (line(table.header), table.rows.map(line))
    }

    /// 显示宽度：CJK / 全角 / emoji 占两个等宽字符。
    static func displayWidth(_ s: String) -> Int {
        var width = 0
        for scalar in s.unicodeScalars {
            width += isWide(scalar) ? 2 : 1
        }
        return width
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,     // 韩文字母
             0x2E80...0x303E,     // CJK 部首 / 标点
             0x3041...0x33FF,     // 假名 / 兼容字符
             0x3400...0x4DBF,     // CJK 扩展 A
             0x4E00...0x9FFF,     // CJK 基本区
             0xA000...0xA4CF,     // 彝文
             0xAC00...0xD7A3,     // 韩文音节
             0xF900...0xFAFF,     // 兼容表意
             0xFE30...0xFE6F,     // 兼容形式
             0xFF00...0xFF60,     // 全角 ASCII
             0xFFE0...0xFFE6,     // 全角符号
             0x1F300...0x1F64F,   // emoji
             0x1F900...0x1F9FF,
             0x20000...0x3FFFD:   // CJK 扩展 B 及以后
            return true
        default:
            return false
        }
    }
}

/// Markdown 块。``MessageBody`` 与 `myna markdown-check` 共用同一份解析结果。
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case bullet(depth: Int, text: String)
    case ordered(depth: Int, number: Int, text: String)
    case blockquote(String)
    case rule
    case table(MarkdownTable)
    case code(String, String?)
}

// MARK: - 块级解析

/// 逐行块级解析器。
///
/// 对**流式**场景保持宽容：未闭合的代码块依旧作为代码块输出，半截表格退回段落，
/// 单独一个 `|` 不会被识别成表格，也不会丢字符。
/// Markdown 块解析结果的缓存。
///
/// `MessageBody` 的 `blocks` 是计算属性，视图每次求值都会重新解析；
/// 流式输出期间消息列表会高频重绘，已完成的消息也会被反复解析。
/// 这里按原文缓存结果（最多 200 条，按插入顺序淘汰），文本不变即命中。
@MainActor
enum MarkdownParseCache {
    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []
    private static let limit = 200
    static var hits = 0
    static var misses = 0

    static func blocks(for text: String) -> [MarkdownBlock] {
        if let cached = cache[text] { hits += 1; return cached }
        misses += 1
        let parsed = MarkdownParser.parse(text)
        cache[text] = parsed
        order.append(text)
        while order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return parsed
    }

    static func reset() { cache.removeAll(); order.removeAll(); hits = 0; misses = 0 }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var inCode = false
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if inCode {
                if trimmed.hasPrefix("```") {
                    out.append(.code(code.joined(separator: "\n"), codeLanguage))
                    code = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    code.append(raw)
                }
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = info.isEmpty ? nil : info
                inCode = true
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let h = heading(trimmed) {
                flushParagraph()
                out.append(.heading(h.0, h.1))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                out.append(.rule)
                i += 1
                continue
            }

            if isQuote(raw) {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, isQuote(lines[i]) {
                    quoted.append(stripQuote(lines[i]))
                    i += 1
                }
                out.append(.blockquote(quoted.joined(separator: "\n")))
                continue
            }

            // 表格必须先于列表判断：`| a | b |` 与 `| - |` 里也可能出现 `-`。
            if let (table, consumed) = table(at: i, in: lines) {
                flushParagraph()
                out.append(.table(table))
                i += consumed
                continue
            }

            if let b = bullet(raw) {
                flushParagraph()
                out.append(.bullet(depth: b.depth, text: b.text))
                i += 1
                continue
            }

            if let o = ordered(raw) {
                flushParagraph()
                // 起始编号以源码为准（例如 `3.` 从 3 开始），连续项依次递增。
                var number = o.number
                if case .ordered(let depth, let previous, _)? = out.last, depth == o.depth {
                    number = previous + 1
                }
                out.append(.ordered(depth: o.depth, number: number, text: o.text))
                i += 1
                continue
            }

            paragraph.append(raw)
            i += 1
        }

        // 未闭合的围栏：仍然输出代码块，绝不丢内容。
        if inCode { out.append(.code(code.joined(separator: "\n"), codeLanguage)) }
        flushParagraph()
        return out.isEmpty ? [.paragraph(text)] : out
    }

    // MARK: 单个构造

    static func heading(_ s: String) -> (Int, String)? {
        let hashes = s.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = s.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// 分隔线：同一字符（`-` / `*` / `_`）至少 3 个，且整行只有它。
    static func isRule(_ s: String) -> Bool {
        let compact = s.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func isQuote(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    /// 去掉引用标记（支持 `> `、`>`、嵌套 `>>`），保留内容缩进。
    static func stripQuote(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(">") {
            s.removeFirst()
            if s.hasPrefix(" ") { s.removeFirst() }
        }
        return s
    }

    /// 前导缩进宽度（空格 1、制表符 2），列表层级 = 宽度 / 2。
    static func indentDepth(_ raw: String) -> Int {
        var width = 0
        for ch in raw {
            if ch == " " {
                width += 1
            } else if ch == "\t" {
                width += 2
            } else {
                break
            }
        }
        return min(width / 2, 6)
    }

    static func bullet(_ raw: String) -> (depth: Int, text: String)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        for p in ["- ", "* ", "+ "] where s.hasPrefix(p) {
            let text = String(s.dropFirst(p.count))
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (indentDepth(raw), text)
        }
        return nil
    }

    static func ordered(_ raw: String) -> (depth: Int, number: Int, text: String)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber, digits.count < 9 {
            digits.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !digits.isEmpty, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
        let afterMarker = s.index(after: idx)
        guard afterMarker < s.endIndex, s[afterMarker] == " " else { return nil }
        let text = String(s[s.index(after: afterMarker)...])
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (indentDepth(raw), Int(digits) ?? 1, text)
    }

    // MARK: 表格

    /// 按 `|` 拆单元格；不含 `|` 的行返回 nil。
    static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.contains("|") else { return nil }
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let cells = s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    /// 表格分隔行：每个单元格是 `---` / `:--` / `--:` / `:-:`。
    static func tableSeparator(_ line: String) -> [String]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        for cell in cells {
            var body = cell
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        }
        return cells
    }

    /// 第 `i` 行是表头且第 `i+1` 行是分隔行时返回表格与该块占用的行数。
    static func table(at i: Int, in lines: [String]) -> (MarkdownTable, Int)? {
        guard i + 1 < lines.count else { return nil }
        guard let header = tableCells(lines[i]),
              let separator = tableSeparator(lines[i + 1]),
              separator.count == header.count else { return nil }

        var rows: [[String]] = []
        var j = i + 2
        while j < lines.count {
            let line = lines[j]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let cells = tableCells(line) else { break }
            rows.append(cells)
            j += 1
        }
        // 行内单元格多寡不一致时补齐，保证列数一致（流式半截表格也安全）。
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        var normalizedHeader = header
        while normalizedHeader.count < columns { normalizedHeader.append("") }
        var normalizedRows = rows
        for r in normalizedRows.indices {
            while normalizedRows[r].count < columns { normalizedRows[r].append("") }
        }
        return (MarkdownTable(header: normalizedHeader, rows: normalizedRows), j - i)
    }
}

// MARK: - 块级排版参数

/// 块级排版尺寸。集中在这里，聊天渲染与 `myna markdown-check` 用同一套数值。
enum MarkdownLayout {
    static func headingSize(_ level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 7
        case 2: return base + 4
        case 3: return base + 2
        default: return base
        }
    }

    static func headingWeight(_ level: Int) -> Font.Weight {
        switch level {
        case 1: return .bold
        case 2, 3: return .semibold
        default: return .semibold
        }
    }

    /// 层级对应的列表符号：`•` / `◦` / `▪` 循环。
    static func bulletMark(depth: Int) -> String {
        let marks = ["•", "◦", "▪"]
        return marks[max(0, depth) % marks.count]
    }

    /// 每层缩进 14pt。
    static func listIndent(depth: Int) -> CGFloat {
        CGFloat(max(0, depth)) * 14
    }

    /// 相邻块之间的垂直间距（连续列表项收紧，标题上下留白）。
    static func gap(_ previous: MarkdownBlock?, _ current: MarkdownBlock) -> CGFloat {
        guard let previous else { return 0 }
        let prevList = listKind(previous)
        let curList = listKind(current)
        if let p = prevList, let c = curList, p.ordered == c.ordered {
            return p.depth == c.depth ? 1 : 3
        }
        if case .heading(let level, _) = current { return level <= 2 ? 10 : 8 }
        if case .heading = previous { return 6 }
        if case .rule = current { return 8 }
        if case .rule = previous { return 8 }
        if curList != nil { return 4 }
        return 6
    }

    private static func listKind(_ block: MarkdownBlock) -> (depth: Int, ordered: Bool)? {
        switch block {
        case .bullet(let depth, _): return (depth, false)
        case .ordered(let depth, _, _): return (depth, true)
        default: return nil
        }
    }
}
