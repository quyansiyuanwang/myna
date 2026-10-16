import Foundation

/// 接口类型（协议）。配置里只指明协议，而不是厂商。
enum APIType: String, CaseIterable, Identifiable {
    case openAICompletions = "openai-completions"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"
    case googleGenerativeAI = "google-generative-ai"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAICompletions: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        case .googleGenerativeAI: return "Google Generative AI"
        }
    }

    /// 该协议是否已在端口（pi-ai-swift）中实现。
    var isImplemented: Bool { self == .openAICompletions }

    static func from(_ raw: String) -> APIType { APIType(rawValue: raw) ?? .openAICompletions }
}

/// 模型快捷切换的候选：当前模型 + 最近使用过的模型（厂商中立）。
enum ModelCatalog {
    static func suggestions(current: String, recent: [String]) -> [String] {
        var list = recent.filter { !$0.isEmpty }
        if !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }
}
