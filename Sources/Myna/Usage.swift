import Foundation
import PiKit

/// 一次运行（可能包含多轮工具调用）的 token 用量。
///
/// 与 `Usage` 的区别：这里的分项是**累加值**，并额外记录请求次数。
/// `input` 是「未命中缓存的输入」，`cacheRead` 是服务端复用的前缀；
/// 因此 `promptTokens = input + cacheRead + cacheWrite`，
/// 命中率按 token 加权，而不是按请求次数平均。
struct TokenUsage: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// 本轮实际发出的模型请求数（一次工具往返算一次）。
    var requests = 0
    /// 估算费用（人民币）。单价来自内置 DeepSeek 价格表或 `model_prices` 覆盖。
    var costCNY: Double = 0

    var promptTokens: Int { input + cacheRead + cacheWrite }
    var totalTokens: Int { promptTokens + output }

    /// 缓存命中率（0...1）；没有任何 prompt token 时为 nil。
    var hitRate: Double? {
        guard promptTokens > 0 else { return nil }
        return min(1, max(0, Double(cacheRead) / Double(promptTokens)))
    }

    var isEmpty: Bool {
        input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0
            && requests == 0 && costCNY == 0
    }

    mutating func add(_ other: TokenUsage) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        requests += other.requests
        costCNY += other.costCNY
    }

    /// 累加一条 assistant 消息的服务端用量（一次请求）。
    mutating func add(_ usage: Usage, cost: Double = 0) {
        input += usage.input
        output += usage.output
        cacheRead += usage.cacheRead
        cacheWrite += usage.cacheWrite
        requests += 1
        costCNY += cost
    }

    enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, requests, costCNY
    }

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
         requests: Int = 0, costCNY: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.requests = requests
        self.costCNY = costCNY
    }

    /// 兼容旧会话：`costCNY` 是后加字段，缺失时按 0 读取。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        costCNY = try c.decodeIfPresent(Double.self, forKey: .costCNY) ?? 0
    }

    /// 从一轮运行产生的 assistant 消息中累加用量。
    ///
    /// `messages` 必须是 `agentEnd` 带回的**本轮新增消息**，否则会重复累计。
    static func from(messages: [Message]) -> TokenUsage {
        var result = TokenUsage()
        for message in messages {
            guard case .assistant(let assistant) = message else { continue }
            let usage = assistant.usage
            result.input += usage.input
            result.output += usage.output
            result.cacheRead += usage.cacheRead
            result.cacheWrite += usage.cacheWrite
            result.requests += 1
        }
        return result
    }
}

/// 按自然日累计 Myna 自己的 token 消耗，用于 `daily_token_budget`。
///
/// 只统计本应用发出的请求；DeepSeek Harness 等其它客户端不在此账本内。
enum UsageLedger {
    private struct Ledger: Codable {
        var day: String
        var tokens: Int
        var cost: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Ledger?

    private static var path: String {
        LocalResources.configDir + "/usage.json"
    }

    private static var today: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    private static func read() -> Ledger? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Ledger.self, from: data)
    }

    /// 今天已消耗的 token；跨天自动归零。
    static func todayTokens() -> Int {
        let day = today
        lock.lock(); defer { lock.unlock() }
        let ledger = cached ?? read()
        cached = ledger
        guard let ledger, ledger.day == day else { return 0 }
        return max(0, ledger.tokens)
    }

    static func todayCost() -> Double {
        let day = today
        lock.lock(); defer { lock.unlock() }
        let ledger = cached ?? read()
        cached = ledger
        guard let ledger, ledger.day == day else { return 0 }
        return max(0, ledger.cost)
    }

    static func add(_ tokens: Int, cost: Double = 0) {
        guard tokens > 0 || cost > 0 else { return }
        let day = today
        lock.lock(); defer { lock.unlock() }
        let existing = cached ?? read()
        let base = existing?.day == day ? existing : nil
        let ledger = Ledger(day: day,
                            tokens: max(0, (base?.tokens ?? 0) + max(0, tokens)),
                            cost: max(0, (base?.cost ?? 0) + max(0, cost)))
        cached = ledger
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? FileManager.default.createDirectory(atPath: LocalResources.configDir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: path)
    }

    /// 剩余 token 额度；预算 <= 0 表示不限制。
    static func remaining(budget: Int) -> Int? {
        guard budget > 0 else { return nil }
        return max(0, budget - todayTokens())
    }

    /// 剩余金额额度；预算 <= 0 表示不限制。
    static func remainingCost(budget: Double) -> Double? {
        guard budget > 0 else { return nil }
        return max(0, budget - todayCost())
    }
}
/// 用量文案的统一格式化。界面、提示与自检共用，避免口径不一致。
enum UsageFormat {
    /// 1,234 → 1.2k；1,200,000 → 1.2M。
    static func short(_ value: Int) -> String {
        let negative = value < 0
        let v = abs(value)
        let text: String
        if v >= 1_000_000 {
            let m = Double(v) / 1_000_000
            text = m == m.rounded() ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        } else if v >= 1_000 {
            let k = Double(v) / 1_000
            text = k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        } else {
            text = "\(v)"
        }
        return negative ? "-" + text : text
    }

    /// 人民币金额：小于 1 元时保留更多小数，避免显示成 ¥0.00。
    static func cost(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "¥0" }
        if value < 0.0001 { return "<¥0.0001" }
        if value >= 1 { return String(format: "¥%.2f", value) }
        if value >= 0.01 { return String(format: "¥%.3f", value) }
        return String(format: "¥%.4f", value)
    }

    /// 0.384 → 38%；nil → —。
    static func percent(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        let value = min(1, max(0, rate))
        // 低于 0.1% 但非零时显示 <0.1%，避免看起来像 0。
        if value > 0, value < 0.001 { return "<0.1%" }
        return String(format: "%.0f%%", value * 100)
    }

    /// 单轮摘要，用于对话末尾。
    static func runLine(_ usage: TokenUsage) -> String {
        let requests = usage.requests > 0 ? "\(usage.requests) 次请求" : "请求数未上报"
        if let rate = usage.hitRate {
            return "本轮 \(requests) · 缓存命中 \(percent(rate))"
                + " · 缓存 \(short(usage.cacheRead)) / \(short(usage.promptTokens))"
                + " · 输出 \(short(usage.output))"
                + (usage.costCNY > 0 ? " · ≈\(cost(usage.costCNY))" : "")
        }
        if usage.totalTokens > 0 {
            return "本轮 \(requests) · 输入 \(short(usage.input))"
                + " · 输出 \(short(usage.output)) · 缓存未上报"
        }
        return "本轮 \(requests) · 用量未上报"
    }

    /// 多行明细，用于悬停提示。
    static func detail(_ usage: TokenUsage) -> String {
        var lines = [
            "请求次数：\(usage.requests)",
            "未命中输入：\(usage.input)",
            "缓存读取：\(usage.cacheRead)",
            "缓存写入：\(usage.cacheWrite)",
            "输出：\(usage.output)",
            "提示词合计：\(usage.promptTokens)",
            "估算费用：\(cost(usage.costCNY))",
        ]
        if let rate = usage.hitRate {
            lines.append("缓存命中率：\(percent(rate))（按 token 加权）")
        } else {
            lines.append("缓存命中率：服务端未上报")
        }
        return lines.joined(separator: "\n")
    }

    /// 会话累计摘要，用于顶栏与会话列表。
    static func cumulativeLine(_ usage: TokenUsage) -> String {
        guard usage.requests > 0 || usage.totalTokens > 0 else { return "暂无用量" }
        guard usage.requests > 0 else {
            // 旧版本只记了 input/output，没有 cacheRead 与请求数；
            // 这时显示 0% 会误导，明确标注「未记录」。
            return "请求数未记录 · 未命中 \(short(usage.input)) · 缓存数据未记录"
                + " · 输出 \(short(usage.output))"
        }
        let rate = usage.hitRate.map { "（\(percent($0))）" } ?? ""
        return "\(usage.requests) 次请求 · 未命中 \(short(usage.input))"
            + " · 缓存 \(short(usage.cacheRead))\(rate)"
            + " · 输出 \(short(usage.output))"
    }

    /// 会话列表用的命中率；旧数据没有请求数时返回 —，而不是 0%。
    static func cachePercent(_ usage: TokenUsage) -> String {
        guard usage.requests > 0 else { return "—" }
        return percent(usage.hitRate)
    }
}
