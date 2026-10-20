import Foundation

/// 数字输入的简写解析。
///
/// 上下文窗口、最大 tokens 这类值动辄六位数，让用户手数零很容易出错，
/// 因此允许输入 `128k`、`1M`、`1.5k` 这样带单位的简写。
///
/// 支持：
/// - `k` / `K` = 1 000
/// - `m` / `M` = 1 000 000
/// - `w` / `W` = 10 000（万）
/// - 千位分隔符 `,` 与下划线 `_` 会被忽略
/// - 小数会被四舍五入（`0.5M` → 500000）
enum NumericInput {
    static func parse(_ raw: String) -> Int? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard !trimmed.isEmpty else { return nil }

        var body = trimmed
        var multiplier = 1.0
        if let last = body.last {
            switch last {
            case "k", "K": multiplier = 1_000
            case "m", "M": multiplier = 1_000_000
            case "w", "W": multiplier = 10_000
            default: break
            }
            if multiplier != 1 { body.removeLast() }
        }
        guard !body.isEmpty, let number = Double(body), number.isFinite else { return nil }
        let scaled = (number * multiplier).rounded()
        guard scaled >= 0, scaled <= Double(Int.max) else { return nil }
        return Int(scaled)
    }

    /// 把大数显示成紧凑形式（仅在编辑框里做提示用）。
    static func compact(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)" }
        if value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value % 1_000 == 0 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}
