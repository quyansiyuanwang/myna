import Foundation
import SwiftUI

/// 代码块围栏（```lang）信息串对应的语言。
///
/// 仅用于选择关键字表与注释/字符串规则，不追求完整语法；
/// 无法识别时归入 ``unknown``，仍会按通用规则着色。
enum SyntaxLanguage: String, CaseIterable {
    case swift
    case javascript
    case python
    case json
    case bash
    case go
    case rust
    case java
    case c
    case cpp
    case objc
    case html
    case css
    case sql
    case yaml
    case markdown
    case ruby
    case php
    case kotlin
    case unknown

    /// 依据围栏信息串识别语言（大小写不敏感，支持常见别名）。
    static func detect(_ info: String?) -> SyntaxLanguage {
        guard let raw = info?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        let key = raw
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "\t" })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        switch key {
        case "swift": return .swift
        case "js", "javascript", "jsx", "ts", "typescript", "tsx": return .javascript
        case "python", "py": return .python
        case "json", "jsonc": return .json
        case "bash", "sh", "shell", "zsh": return .bash
        case "go", "golang": return .go
        case "rust", "rs": return .rust
        case "java": return .java
        case "c", "h": return .c
        case "cpp", "c++", "cc", "cxx", "hpp": return .cpp
        case "objc", "objective-c", "objectivec": return .objc
        case "html", "xml", "svg", "xhtml": return .html
        case "css", "scss", "less", "sass": return .css
        case "sql": return .sql
        case "yaml", "yml": return .yaml
        case "markdown", "md": return .markdown
        case "ruby", "rb": return .ruby
        case "php": return .php
        case "kotlin", "kt", "kts": return .kotlin
        default: return .unknown
        }
    }

    /// 代码块标题栏展示的名称；无法识别时为「代码」。
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .json: return "JSON"
        case .bash: return "Shell"
        case .go: return "Go"
        case .rust: return "Rust"
        case .java: return "Java"
        case .c: return "C"
        case .cpp: return "C++"
        case .objc: return "Objective-C"
        case .html: return "HTML"
        case .css: return "CSS"
        case .sql: return "SQL"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .ruby: return "Ruby"
        case .php: return "PHP"
        case .kotlin: return "Kotlin"
        case .unknown: return "代码"
        }
    }
}

/// 词法单元类别。
enum SyntaxTokenKind {
    case plain
    case comment
    case string
    case number
    case keyword
    case type
    case function
}

/// 语言相关的词法规则。
struct SyntaxSpec {
    var keywords: Set<String> = []
    var types: Set<String> = []
    var lineComments: [[Character]] = []
    var blockComments: [(open: [Character], close: [Character])] = []
    var quotes: [Character] = ["\"", "'"]
    var backtickQuote = false
    var tripleQuotes = false
    var stringPrefixes = false
    var backslashEscape = true
    /// `#` 注释是否要求前面是空白（shell 里 `foo#bar` 不是注释）。
    var hashNeedsBoundary = false
}

/// 代码高亮调色板定义见 `Theme.swift`（``SyntaxPalette``）。

/// 纯函数式、单遍扫描的轻量代码高亮器。
///
/// 设计目标：**永不改变输入文本**。它只把字符串切成连续的词法区间，
/// 每个区间映射一种颜色；``highlight(_:language:dark:)`` 在返回前校验
/// `String(结果.characters) == 输入`，不一致时安全回退为无属性纯文本。
enum SyntaxHighlighter {

    /// 高亮一段代码，返回带前景色的 `AttributedString`。
    ///
    /// - Parameters:
    ///   - code: 原始代码，逐字符保留。
    ///   - language: 围栏信息串（可为 nil）。
    ///   - dark: 是否为深色外观。
    /// 高亮结果缓存。
    ///
    /// `CodeBlockView.body` 每次重绘都会调用高亮，而分词 + 构建 AttributedString 与代码
    /// 长度成正比。滚动长文档时同一段代码会被反复求值，缓存后只剩一次。
    private static var cache: [String: AttributedString] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 120

    static func highlight(_ code: String, language: String?, dark: Bool) -> AttributedString {
        let key = "\(dark ? 1 : 0)|\(language ?? "")|\(code.count)|\(code.hashValue)"
        if let hit = cache[key] { return hit }
        let value = highlightUncached(code, language: language, dark: dark)
        if cacheOrder.count >= cacheLimit, let first = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: first)
        }
        cache[key] = value
        cacheOrder.append(key)
        return value
    }

    private static func highlightUncached(_ code: String, language: String?, dark: Bool) -> AttributedString {
        let palette = SyntaxPalette.forAppearance(dark: dark)
        guard !code.isEmpty else { return AttributedString("") }
        let language = SyntaxLanguage.detect(language)
        let chars = Array(code)
        let tokens = tokens(in: chars, language: language)

        var result = AttributedString()
        var cursor = 0
        for token in tokens {
            let lo = max(cursor, token.lower)
            let hi = min(chars.count, token.upper)
            guard lo <= hi else { continue }
            if lo > cursor {
                result.append(AttributedString(String(chars[cursor..<lo])))
            }
            if hi > lo {
                var piece = AttributedString(String(chars[lo..<hi]))
                piece.foregroundColor = palette.color(for: token.kind)
                result.append(piece)
            }
            cursor = max(cursor, hi)
        }
        if cursor < chars.count {
            result.append(AttributedString(String(chars[cursor...])))
        }
        // 不变式：文本必须逐字符一致，否则回退（绝不丢字或乱序）。
        if String(result.characters) != code {
            return AttributedString(code)
        }
        return result
    }

    /// 仅用于调试/自检：返回 (类别, 文本) 列表。
    static func segments(_ code: String, language: String?) -> [(kind: SyntaxTokenKind, text: String)] {
        let chars = Array(code)
        let lang = SyntaxLanguage.detect(language)
        return tokens(in: chars, language: lang).compactMap { token in
            guard token.lower < token.upper, token.upper <= chars.count else { return nil }
            return (token.kind, String(chars[token.lower..<token.upper]))
        }
    }

    // MARK: - 扫描

    private struct Token {
        let lower: Int
        let upper: Int
        let kind: SyntaxTokenKind
    }

    private static func tokens(in chars: [Character], language: SyntaxLanguage) -> [Token] {
        let spec = language.spec
        var out: [Token] = []
        var i = 0
        var plainStart = 0

        func flushPlain(upTo end: Int) {
            if end > plainStart {
                out.append(Token(lower: plainStart, upper: end, kind: .plain))
            }
        }

        while i < chars.count {
            let c = chars[i]

            if let end = blockCommentEnd(chars, at: i, spec: spec) {
                flushPlain(upTo: i)
                out.append(Token(lower: i, upper: end, kind: .comment))
                i = end
                plainStart = i
                continue
            }
            if let end = lineCommentEnd(chars, at: i, spec: spec) {
                flushPlain(upTo: i)
                out.append(Token(lower: i, upper: end, kind: .comment))
                i = end
                plainStart = i
                continue
            }
            if let end = stringEnd(chars, at: i, spec: spec) {
                flushPlain(upTo: i)
                out.append(Token(lower: i, upper: end, kind: .string))
                i = end
                plainStart = i
                continue
            }
            if c.isNumber {
                let end = numberEnd(chars, at: i)
                flushPlain(upTo: i)
                out.append(Token(lower: i, upper: end, kind: .number))
                i = end
                plainStart = i
                continue
            }
            if isIdentifierStart(c) {
                let end = identifierEnd(chars, at: i)
                let word = String(chars[i..<end])
                let kind = classify(word, at: end, chars: chars, spec: spec)
                flushPlain(upTo: i)
                out.append(Token(lower: i, upper: end, kind: kind))
                i = end
                plainStart = i
                continue
            }
            i += 1
        }
        flushPlain(upTo: chars.count)
        return out
    }

    private static func classify(_ word: String, at end: Int, chars: [Character], spec: SyntaxSpec) -> SyntaxTokenKind {
        let lower = word.lowercased()
        if spec.keywords.contains(lower) { return .keyword }
        if spec.types.contains(lower) { return .type }
        if let first = word.first, first.isUppercase { return .type }
        var j = end
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        if j < chars.count, chars[j] == "(" { return .function }
        return .plain
    }

    // MARK: 注释

    private static func blockCommentEnd(_ chars: [Character], at start: Int, spec: SyntaxSpec) -> Int? {
        for rule in spec.blockComments {
            guard matches(chars, at: start, rule.open) else { continue }
            var i = start + rule.open.count
            let closeCount = rule.close.count
            while i <= chars.count - closeCount {
                if matches(chars, at: i, rule.close) { return i + closeCount }
                i += 1
            }
            return chars.count
        }
        return nil
    }

    private static func lineCommentEnd(_ chars: [Character], at start: Int, spec: SyntaxSpec) -> Int? {
        for rule in spec.lineComments {
            guard matches(chars, at: start, rule) else { continue }
            if spec.hashNeedsBoundary, rule == ["#"],
               start > 0, !chars[start - 1].isWhitespace {
                continue
            }
            var i = start
            while i < chars.count, chars[i] != "\n" { i += 1 }
            return i
        }
        return nil
    }

    // MARK: 字符串

    private static func stringEnd(_ chars: [Character], at start: Int, spec: SyntaxSpec) -> Int? {
        var i = start
        if spec.stringPrefixes {
            var p = i
            while p < chars.count, p - i < 2, "rbfuRBFU".contains(chars[p]) { p += 1 }
            if p > i, p < chars.count, isQuote(chars[p], spec: spec) { i = p }
        }
        guard i < chars.count, isQuote(chars[i], spec: spec) else { return nil }
        let quote = chars[i]

        // 三引号（Python docstring）。
        if spec.tripleQuotes, quote == "\"",
           i + 2 < chars.count, chars[i + 1] == quote, chars[i + 2] == quote {
            var j = i + 3
            while j + 2 < chars.count {
                if chars[j] == quote, chars[j + 1] == quote, chars[j + 2] == quote {
                    return j + 3
                }
                j += 1
            }
            return chars.count
        }

        var j = i + 1
        while j < chars.count {
            let c = chars[j]
            if c == "\\", spec.backslashEscape {
                j += 2
                continue
            }
            if c == quote { return j + 1 }
            if c == "\n" { break }
            j += 1
        }
        return min(j, chars.count)
    }

    private static func isQuote(_ c: Character, spec: SyntaxSpec) -> Bool {
        if spec.quotes.contains(c) { return true }
        if spec.backtickQuote, c == "`" { return true }
        return false
    }

    // MARK: 数字 / 标识符

    private static func numberEnd(_ chars: [Character], at start: Int) -> Int {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c.isLetter || c.isNumber || c == "." || c == "_" {
                i += 1
            } else {
                break
            }
        }
        return i
    }

    private static func identifierEnd(_ chars: [Character], at start: Int) -> Int {
        var i = start
        while i < chars.count, isIdentifierChar(chars[i]) { i += 1 }
        return i
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter
    }

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter || c.isNumber
    }

    private static func matches(_ chars: [Character], at start: Int, _ needle: [Character]) -> Bool {
        guard start >= 0, start + needle.count <= chars.count else { return false }
        for k in 0..<needle.count where chars[start + k] != needle[k] { return false }
        return true
    }
}

// MARK: - 各语言规则

private extension SyntaxLanguage {
    var spec: SyntaxSpec {
        switch self {
        case .swift:
            return SyntaxSpec(
                keywords: Self.swiftKeywords,
                types: Self.commonTypes.union(["string", "int", "double", "bool", "any", "void"]),
                lineComments: [Array("//")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        case .javascript:
            return SyntaxSpec(
                keywords: Self.jsKeywords,
                types: Self.commonTypes.union(["console", "math", "json", "promise", "array", "object", "string", "number", "boolean"]),
                lineComments: [Array("//")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"],
                backtickQuote: true
            )
        case .python:
            return SyntaxSpec(
                keywords: Self.pythonKeywords,
                types: Self.commonTypes.union(["str", "int", "float", "bool", "list", "dict", "set", "tuple", "none"]),
                lineComments: [Array("#")],
                quotes: ["\"", "'"],
                tripleQuotes: true,
                stringPrefixes: true
            )
        case .json:
            return SyntaxSpec(
                keywords: ["true", "false", "null"],
                types: [],
                lineComments: [],
                blockComments: [],
                quotes: ["\""]
            )
        case .bash:
            return SyntaxSpec(
                keywords: Self.bashKeywords,
                types: [],
                lineComments: [Array("#")],
                quotes: ["\"", "'"],
                backtickQuote: true,
                hashNeedsBoundary: true
            )
        case .go:
            return SyntaxSpec(
                keywords: Self.goKeywords,
                types: Self.commonTypes.union(["string", "int", "int64", "float64", "bool", "byte", "rune", "error", "any"]),
                lineComments: [Array("//")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"],
                backtickQuote: true
            )
        case .rust:
            return SyntaxSpec(
                keywords: Self.rustKeywords,
                types: Self.commonTypes.union(["string", "str", "i32", "i64", "u32", "u64", "usize", "f32", "f64", "bool", "vec", "option", "result"]),
                lineComments: [Array("//")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        case .java:
            return SyntaxSpec(
                keywords: Self.javaKeywords,
                types: Self.commonTypes.union(["string", "int", "long", "double", "float", "boolean", "char", "byte", "list", "map"]),
                lineComments: [Array("//")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        case .c, .cpp, .objc:
            return SyntaxSpec(
                keywords: Self.cKeywords.union(self == .cpp || self == .objc ? Self.cppKeywords : []),
                types: Self.commonTypes.union(["int", "long", "double", "float", "char", "bool", "void", "size_t", "uint32_t", "nsstring"]),
                lineComments: [Array("//")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        case .kotlin:
            return SyntaxSpec(
                keywords: Self.kotlinKeywords,
                types: Self.commonTypes.union(["string", "int", "long", "double", "float", "boolean", "list", "map", "any"]),
                lineComments: [Array("//")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        case .html:
            return SyntaxSpec(
                keywords: [],
                types: [],
                lineComments: [],
                blockComments: [(Array("<!--"), Array("-->"))],
                quotes: ["\"", "'"]
            )
        case .css:
            return SyntaxSpec(
                keywords: [],
                types: [],
                lineComments: [],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        case .sql:
            return SyntaxSpec(
                keywords: Self.sqlKeywords,
                types: [],
                lineComments: [Array("--")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["'", "\""]
            )
        case .yaml:
            return SyntaxSpec(
                keywords: ["true", "false", "null", "yes", "no"],
                types: [],
                lineComments: [Array("#")],
                quotes: ["\"", "'"],
                hashNeedsBoundary: true
            )
        case .markdown:
            return SyntaxSpec(
                keywords: [],
                types: [],
                lineComments: [],
                quotes: [],
                backtickQuote: true
            )
        case .ruby:
            return SyntaxSpec(
                keywords: Self.rubyKeywords,
                types: [],
                lineComments: [Array("#")],
                quotes: ["\"", "'"],
                stringPrefixes: false
            )
        case .php:
            return SyntaxSpec(
                keywords: Self.phpKeywords,
                types: [],
                lineComments: [Array("//"), Array("#")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        case .unknown:
            return SyntaxSpec(
                keywords: Self.genericKeywords,
                types: [],
                lineComments: [Array("//"), Array("#"), Array("%")],
                blockComments: [(Array("/*"), Array("*/"))],
                quotes: ["\"", "'"]
            )
        }
    }

    // MARK: 关键字表

    static let genericKeywords: Set<String> = [
        "if", "else", "for", "while", "return", "function", "func", "class", "struct",
        "enum", "import", "export", "var", "let", "const", "new", "true", "false", "null",
        "nil", "try", "catch", "throw", "async", "await", "public", "private",
    ]

    static let commonTypes: Set<String> = [
        "string", "array", "object", "dictionary", "set", "map", "list",
    ]

    static let swiftKeywords: Set<String> = [
        "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import",
        "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "return",
        "break", "continue", "throw", "throws", "rethrows", "try", "catch", "defer", "do",
        "in", "where", "as", "is", "nil", "true", "false", "self", "super", "init", "deinit",
        "public", "private", "fileprivate", "internal", "open", "static", "final", "lazy",
        "mutating", "nonmutating", "override", "required", "convenience", "typealias", "associatedtype",
        "some", "any", "async", "await", "actor", "nonisolated", "isolated", "consume", "borrowing",
        "inout", "subscript", "get", "set", "willSet", "didSet", "indirect", "convenience",
    ]

    static let jsKeywords: Set<String> = [
        "var", "let", "const", "function", "return", "if", "else", "for", "while", "do",
        "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof",
        "this", "super", "class", "extends", "import", "export", "from", "as", "try", "catch",
        "finally", "throw", "async", "await", "yield", "true", "false", "null", "undefined",
        "void", "in", "of", "static", "get", "set",
    ]

    static let pythonKeywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue",
        "import", "from", "as", "pass", "raise", "try", "except", "finally", "with", "lambda",
        "global", "nonlocal", "assert", "del", "yield", "async", "await", "in", "is", "not",
        "and", "or", "none", "true", "false", "self",
    ]

    static let bashKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do",
        "done", "in", "function", "select", "time", "return", "exit", "local", "export",
        "readonly", "declare", "set", "unset", "shift", "source", "alias", "echo",
    ]

    static let goKeywords: Set<String> = [
        "package", "import", "func", "var", "const", "type", "struct", "interface", "map",
        "chan", "go", "defer", "if", "else", "for", "range", "switch", "case", "default",
        "break", "continue", "return", "goto", "fallthrough", "select", "nil", "true", "false",
        "make", "new", "append", "len", "cap", "panic", "recover",
    ]

    static let rustKeywords: Set<String> = [
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "pub",
        "use", "mod", "crate", "super", "self", "match", "if", "else", "for", "while", "loop",
        "break", "continue", "return", "move", "ref", "as", "in", "where", "async", "await",
        "dyn", "box", "unsafe", "true", "false", "none", "some", "ok", "err",
    ]

    static let javaKeywords: Set<String> = [
        "public", "private", "protected", "class", "interface", "enum", "extends", "implements",
        "static", "final", "abstract", "void", "int", "long", "double", "float", "boolean",
        "char", "byte", "new", "return", "if", "else", "for", "while", "do", "switch", "case",
        "default", "break", "continue", "try", "catch", "finally", "throw", "throws", "import",
        "package", "this", "super", "true", "false", "null", "instanceof", "synchronized",
    ]

    static let cKeywords: Set<String> = [
        "int", "long", "short", "char", "float", "double", "void", "signed", "unsigned",
        "struct", "union", "enum", "typedef", "static", "extern", "const", "volatile",
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "return", "goto", "sizeof", "true", "false", "null", "include", "define",
    ]

    static let cppKeywords: Set<String> = [
        "class", "public", "private", "protected", "namespace", "using", "template", "typename",
        "new", "delete", "this", "nullptr", "true", "false", "auto", "constexpr", "virtual",
        "override", "try", "catch", "throw", "bool", "string", "vector",
    ]

    static let kotlinKeywords: Set<String> = [
        "fun", "val", "var", "class", "object", "interface", "data", "sealed", "enum", "when",
        "if", "else", "for", "while", "do", "return", "break", "continue", "import", "package",
        "try", "catch", "finally", "throw", "true", "false", "null", "this", "super", "is",
        "in", "as", "by", "suspend", "override", "open", "private", "public", "internal",
    ]

    static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
        "create", "table", "alter", "drop", "index", "join", "inner", "left", "right", "outer",
        "on", "group", "by", "order", "having", "limit", "offset", "distinct", "as", "and",
        "or", "not", "null", "is", "in", "like", "between", "exists", "union", "all", "case",
        "when", "then", "else", "end", "primary", "key", "foreign", "references", "default",
    ]

    static let rubyKeywords: Set<String> = [
        "def", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for",
        "do", "end", "return", "yield", "begin", "rescue", "ensure", "raise", "require",
        "attr_accessor", "attr_reader", "attr_writer", "self", "nil", "true", "false", "and",
        "or", "not", "then", "case", "when", "new", "lambda", "proc", "puts",
    ]

    static let phpKeywords: Set<String> = [
        "function", "class", "interface", "trait", "extends", "implements", "public", "private",
        "protected", "static", "final", "abstract", "return", "if", "else", "elseif", "for",
        "foreach", "while", "do", "switch", "case", "default", "break", "continue", "try",
        "catch", "finally", "throw", "new", "echo", "print", "true", "false", "null", "use",
        "namespace", "as", "instanceof",
    ]
}
