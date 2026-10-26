import Foundation
import PiKit

/// 单个模型的人民币单价（每百万 tokens）。空闲/高峰两档。
struct ModelPrice: Codable, Equatable, Sendable {
    var inputOffPeak: Double
    var inputPeak: Double
    var cacheReadOffPeak: Double
    var cacheReadPeak: Double
    var outputOffPeak: Double
    var outputPeak: Double

    init(inputOffPeak: Double, inputPeak: Double,
         cacheReadOffPeak: Double, cacheReadPeak: Double,
         outputOffPeak: Double, outputPeak: Double) {
        self.inputOffPeak = inputOffPeak
        self.inputPeak = inputPeak
        self.cacheReadOffPeak = cacheReadOffPeak
        self.cacheReadPeak = cacheReadPeak
        self.outputOffPeak = outputOffPeak
        self.outputPeak = outputPeak
    }
}

/// 价格表与费用估算。
///
/// 只负责估算，不替代平台账单。DeepSeek 的高峰时段为北京时间周一至周五
/// 09:00–12:00、14:00–18:00；法定节假日未单独排除，节假日会按高峰估算。
enum Pricing {
    private static let deepSeekFlash = ModelPrice(
        inputOffPeak: 1.0, inputPeak: 2.0,
        cacheReadOffPeak: 0.02, cacheReadPeak: 0.04,
        outputOffPeak: 4.0, outputPeak: 8.0
    )

    private static let deepSeekPro = ModelPrice(
        inputOffPeak: 4.5, inputPeak: 9.0,
        cacheReadOffPeak: 0.15, cacheReadPeak: 0.30,
        outputOffPeak: 13.5, outputPeak: 27.0
    )

    private static let builtIns: [String: ModelPrice] = [
        "deepseek-flash": deepSeekFlash,
        "deepseek-v4-flash": deepSeekFlash,
        "deepseek-v4-flash-vision-exp": deepSeekFlash,
        "deepseek-v4-pro": deepSeekPro,
    ]

    /// 用户配置优先，其次是内置表。
    static func resolve(_ model: String, _ settings: AppSettings) -> ModelPrice? {
        settings.modelPrices[model] ?? builtIns[model]
    }

    static func isPeak(_ date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        guard (2...6).contains(weekday) else { return false }
        let hour = calendar.component(.hour, from: date)
        return (9..<12).contains(hour) || (14..<18).contains(hour)
    }

    static func cost(_ usage: Usage, model: String, at date: Date = Date(),
                     settings: AppSettings) -> Double {
        guard let price = resolve(model, settings) else { return 0 }
        let peak = isPeak(date)
        let inputRate = peak ? price.inputPeak : price.inputOffPeak
        let cacheRate = peak ? price.cacheReadPeak : price.cacheReadOffPeak
        let outputRate = peak ? price.outputPeak : price.outputOffPeak
        return Double(usage.input) / 1_000_000 * inputRate
            + Double(usage.cacheRead) / 1_000_000 * cacheRate
            + Double(usage.cacheWrite) / 1_000_000 * inputRate
            + Double(usage.output) / 1_000_000 * outputRate
    }

    static func cost(_ usage: TokenUsage, model: String, at date: Date = Date(),
                     settings: AppSettings) -> Double {
        guard let price = resolve(model, settings) else { return 0 }
        let peak = isPeak(date)
        let inputRate = peak ? price.inputPeak : price.inputOffPeak
        let cacheRate = peak ? price.cacheReadPeak : price.cacheReadOffPeak
        let outputRate = peak ? price.outputPeak : price.outputOffPeak
        return Double(usage.input) / 1_000_000 * inputRate
            + Double(usage.cacheRead) / 1_000_000 * cacheRate
            + Double(usage.cacheWrite) / 1_000_000 * inputRate
            + Double(usage.output) / 1_000_000 * outputRate
    }

    static func describe(_ model: String, _ settings: AppSettings) -> String {
        guard let p = resolve(model, settings) else {
            return "未配置「\(model)」的单价；可在 config.json 的 model_prices 添加"
        }
        return "命中 ¥\(short(p.cacheReadOffPeak))–\(short(p.cacheReadPeak))/M"
            + " · 未命中 ¥\(short(p.inputOffPeak))–\(short(p.inputPeak))/M"
            + " · 输出 ¥\(short(p.outputOffPeak))–\(short(p.outputPeak))/M（空闲–高峰）"
    }

    private static func short(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
