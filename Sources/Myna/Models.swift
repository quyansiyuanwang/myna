import Foundation

/// 常用模型建议。按 `baseURL` 推断供应商，并把当前模型置于首位。
enum ModelCatalog {
    static func suggestions(for baseURL: String, current: String) -> [String] {
        let b = baseURL.lowercased()
        var list: [String]
        if b.contains("deepseek") {
            list = ["deepseek-chat", "deepseek-reasoner", "deepseek-flash"]
        } else if b.contains("openai") {
            list = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "o4-mini"]
        } else if b.contains("ollama") || b.contains("localhost") || b.contains("127.0.0.1") {
            list = ["llama3.1", "qwen2.5", "mistral", "phi4"]
        } else {
            list = []
        }
        if !current.isEmpty, !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list
    }
}
