import SwiftUI
import AppKit

/// 强调色选项
enum AccentOption: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .graphite: return "石墨"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.20, green: 0.51, blue: 0.98)
        case .purple: return Color(red: 0.58, green: 0.35, blue: 0.96)
        case .pink: return Color(red: 0.96, green: 0.36, blue: 0.62)
        case .red: return Color(red: 0.94, green: 0.30, blue: 0.30)
        case .orange: return Color(red: 0.98, green: 0.55, blue: 0.16)
        case .yellow: return Color(red: 0.93, green: 0.72, blue: 0.12)
        case .green: return Color(red: 0.22, green: 0.72, blue: 0.40)
        case .graphite: return Color(red: 0.45, green: 0.47, blue: 0.50)
        }
    }

    static func from(_ raw: String) -> AccentOption { AccentOption(rawValue: raw) ?? .blue }
}

/// 外观模式
enum AppearanceOption: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func from(_ raw: String) -> AppearanceOption { AppearanceOption(rawValue: raw) ?? .system }
}

/// 信息密度
enum DensityOption: String, CaseIterable, Identifiable {
    case compact, comfortable
    var id: String { rawValue }

    var label: String { self == .compact ? "紧凑" : "宽松" }

    var rowSpacing: CGFloat { self == .compact ? 6 : 10 }
    var contentPadding: CGFloat { self == .compact ? 8 : 12 }
    var bubblePaddingH: CGFloat { self == .compact ? 9 : 11 }
    var bubblePaddingV: CGFloat { self == .compact ? 5 : 7 }

    static func from(_ raw: String) -> DensityOption { DensityOption(rawValue: raw) ?? .comfortable }
}

/// 由设置派生的聊天界面主题
struct ChatTheme: Equatable {
    let accent: Color
    let fontSize: CGFloat
    let density: DensityOption
    let cornerRadius: CGFloat
    let showAvatars: Bool
    let showTimestamps: Bool
    let markdown: Bool

    init(_ s: AppSettings) {
        accent = AccentOption.from(s.accent).color
        fontSize = CGFloat(s.fontSize)
        density = DensityOption.from(s.density)
        cornerRadius = CGFloat(s.bubbleCornerRadius)
        showAvatars = s.showAvatars
        showTimestamps = s.showTimestamps
        markdown = s.markdownEnabled
    }

    var bodyFont: Font { .system(size: fontSize) }
    var smallFont: Font { .system(size: max(10, fontSize - 2)) }
    var tinyFont: Font { .system(size: max(9, fontSize - 3)) }
    var nameFont: Font { .system(size: max(10, fontSize - 2), weight: .semibold) }

    /// 用户气泡：强调色
    var userBubble: Color { accent }
    /// 助手气泡：随明暗自适应的中性色
    var assistantBubble: Color { Color(nsColor: .controlBackgroundColor) }
    /// 工具气泡：更弱的中性色
    var toolBubble: Color { Color(nsColor: .textBackgroundColor).opacity(0.55) }
    /// 气泡描边
    var bubbleStroke: Color { Color.primary.opacity(0.08) }

    /// 代码高亮调色板（按明暗外观取用）。
    func syntaxPalette(dark: Bool) -> SyntaxPalette { SyntaxPalette.forAppearance(dark: dark) }
}

/// 代码高亮调色板（明暗两套）。
///
/// 令牌器只按语义类别取色，颜色本身集中在此处，便于随主题统一调整。
struct SyntaxPalette {
    let keyword: Color
    let string: Color
    let number: Color
    let comment: Color
    let type: Color
    let function: Color
    let plain: Color

    static func forAppearance(dark: Bool) -> SyntaxPalette {
        if dark {
            return SyntaxPalette(
                keyword: Color(red: 0.99, green: 0.37, blue: 0.64),
                string: Color(red: 0.99, green: 0.42, blue: 0.36),
                number: Color(red: 0.82, green: 0.75, blue: 0.41),
                comment: Color(red: 0.44, green: 0.50, blue: 0.56),
                type: Color(red: 0.36, green: 0.85, blue: 1.00),
                function: Color(red: 0.40, green: 0.72, blue: 0.65),
                plain: Color(nsColor: .labelColor)
            )
        }
        return SyntaxPalette(
            keyword: Color(red: 0.61, green: 0.14, blue: 0.58),
            string: Color(red: 0.77, green: 0.10, blue: 0.09),
            number: Color(red: 0.11, green: 0.00, blue: 0.81),
            comment: Color(red: 0.33, green: 0.40, blue: 0.47),
            type: Color(red: 0.06, green: 0.41, blue: 0.63),
            function: Color(red: 0.24, green: 0.50, blue: 0.53),
            plain: Color(nsColor: .labelColor)
        )
    }

    func color(for kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .keyword: return keyword
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .type: return type
        case .function: return function
        case .plain: return plain
        }
    }
}

/// 头像 / 角色标识
enum ChatRole: String {
    case user, assistant, thinking, tool, toolResult, error

    var icon: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .thinking: return "brain"
        case .tool: return "wrench.and.screwdriver.fill"
        case .toolResult: return "arrow.turn.down.right"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var name: String {
        switch self {
        case .user: return "你"
        case .assistant: return "Myna"
        case .thinking: return "思考"
        case .tool: return "工具调用"
        case .toolResult: return "工具结果"
        case .error: return "错误"
        }
    }

    /// 是否以可折叠区块呈现。
    var isCollapsible: Bool {
        switch self {
        case .thinking, .tool, .toolResult: return true
        default: return false
        }
    }

    static func from(_ raw: String) -> ChatRole {
        switch raw {
        case "user": return .user
        case "tool": return .tool
        case "toolResult": return .toolResult
        case "thinking": return .thinking
        case "error": return .error
        default: return .assistant
        }
    }
}
