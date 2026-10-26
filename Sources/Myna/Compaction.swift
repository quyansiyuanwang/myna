import Foundation
import PiKit

/// 一次上下文压缩的纯数据计划，便于自检与失败回退。
struct CompactionPlan {
    var summaryInput: String
    var recent: [Message]
    var beforeTokens: Int
    var keptTurns: Int
    var droppedMessages: Int
}

/// 把旧对话摘要成一段稳定的前缀。
enum ContextCompactor {
    static let summaryInstruction = """
    你负责压缩 Agent 对话历史。请把下面的旧对话压缩成简洁的中文摘要，必须保留：
    1. 用户的目标与约束、已确认的事实；
    2. 未完成事项与下一步；
    3. 涉及的文件路径、命令、关键数据；
    4. 工具调用中得到的重要结果（不要保留冗长的原始输出）。
    不要编造，不要输出分析过程，只输出摘要正文。
    """

    /// 只在用户消息处切分，避免留下孤立的 tool result。
    static func plan(messages: [Message], keepTurns: Int) -> CompactionPlan? {
        let turns = max(1, keepTurns)
        let userIndices = messages.indices.filter {
            if case .user = messages[$0] { return true }
            return false
        }
        guard userIndices.count > turns else { return nil }
        let cut = userIndices[userIndices.count - turns]
        let old = Array(messages[..<cut])
        let recent = Array(messages[cut...])
        guard !old.isEmpty else { return nil }
        return CompactionPlan(summaryInput: render(old),
                              recent: recent,
                              beforeTokens: estimateRaw(messages),
                              keptTurns: turns,
                              droppedMessages: old.count)
    }

    static func summarize(_ plan: CompactionPlan, settings: AppSettings) async -> (String, TokenUsage)? {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let provider = PackageRuntime.makeProvider(settings)
        let model = PackageRuntime.makeModel(settings)
        // 摘要输入本身也设上限，避免为了压缩再发一次超大请求。
        let input = String(plan.summaryInput.prefix(60_000))
        let context = ChatContext(
            systemPrompt: summaryInstruction,
            messages: [.user(UserMessage(content: input,
                                         timestamp: Int(Date().timeIntervalSince1970 * 1000)))]
        )
        let options = ChatOptions(apiKey: settings.apiKey,
                                  temperature: 0.2,
                                  maxTokens: settings.compactMaxTokens)
        var text = ""
        var usage = TokenUsage()
        do {
            for try await event in provider.stream(model: model, context: context, options: options) {
                switch event {
                case .textDelta(let delta): text += delta
                case .done(let message): usage.add(message.usage)
                case .error(let error): throw error
                default: break
                }
            }
        } catch {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, usage)
    }

    static func assemble(summary: String, recent: [Message]) -> [Message] {
        let header = "【此前对话摘要】\n\(summary)\n\n（以上为压缩摘要，以下是最近保留的对话。）"
        var out: [Message] = [.user(UserMessage(content: header,
                                                timestamp: Int(Date().timeIntervalSince1970 * 1000)))]
        out.append(contentsOf: recent)
        return out
    }

    static func estimate(_ text: String) -> Int {
        var ascii = 0, cjk = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 0x2E80 { ascii += 1 } else { cjk += 1 }
        }
        return Int(Double(ascii) / 4.0 + Double(cjk) / 1.5)
    }

    static func estimate(_ messages: [Message]) -> Int {
        estimate(render(messages))
    }

    /// 未截断的粗略估算，用于判断是否触发自动压缩。
    static func estimateRaw(_ messages: [Message]) -> Int {
        var ascii = 0, cjk = 0
        func count(_ text: String) {
            for scalar in text.unicodeScalars {
                if scalar.value < 0x2E80 { ascii += 1 } else { cjk += 1 }
            }
        }
        for message in messages {
            switch message {
            case .system(let system):
                if case .text(let text) = system.content { count(text) }
            case .user(let user):
                switch user.content {
                case .text(let text): count(text)
                case .blocks(let blocks):
                    for block in blocks {
                        switch block {
                        case .text(let text): count(text.text)
                        case .thinking(let thinking): count(thinking.thinking)
                        case .toolCall(let call): count("\(call.name) \(PackageRuntime.describe(call.arguments))")
                        case .image: count("image")
                        }
                    }
                }
            case .assistant(let assistant):
                for block in assistant.content {
                    switch block {
                    case .text(let text): count(text.text)
                    case .thinking(let thinking): count(thinking.thinking)
                    case .toolCall(let call): count("\(call.name) \(PackageRuntime.describe(call.arguments))")
                    case .image: count("image")
                    }
                }
            case .toolResult(let result):
                for block in result.content {
                    if case .text(let text) = block { count(text.text) }
                }
            }
        }
        return Int(Double(ascii) / 4.0 + Double(cjk) / 1.5)
    }

    /// 渲染成摘要输入；单个工具结果最多保留 2000 字，避免二次撑爆上下文。
    static func render(_ messages: [Message]) -> String {
        var lines: [String] = []
        for message in messages {
            switch message {
            case .system(let system):
                lines.append("[system] \(contentText(system.content))")
            case .user(let user):
                lines.append("[user] \(contentText(user.content))")
            case .assistant(let assistant):
                var parts: [String] = []
                for block in assistant.content {
                    switch block {
                    case .text(let text): parts.append(text.text)
                    case .thinking(let thinking): parts.append("思考：\(thinking.thinking.prefix(400))")
                    case .toolCall(let call):
                        parts.append("调用工具 \(call.name) \(PackageRuntime.describe(call.arguments))")
                    case .image: parts.append("[图片]")
                    }
                }
                lines.append("[assistant] \(parts.joined(separator: " "))")
            case .toolResult(let result):
                let text = result.content.compactMap { block -> String? in
                    if case .text(let value) = block { return value.text }
                    if case .image = block { return "[图片]" }
                    return nil
                }.joined(separator: "\n")
                lines.append("[tool:\(result.toolName)] \(String(text.prefix(2_000)))")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private static func contentText(_ content: MessageContent) -> String {
        switch content {
        case .text(let value): return value
        case .blocks(let blocks):
            return blocks.compactMap { block -> String? in
                switch block {
                case .text(let value): return value.text
                case .image: return "[图片]"
                case .thinking(let value): return value.thinking
                case .toolCall(let call): return "\(call.name) \(PackageRuntime.describe(call.arguments))"
                }
            }.joined(separator: "\n")
        }
    }
}
