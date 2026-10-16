import Foundation
import PiKit

/// 持久化的一条消息（用于导出 / 多会话）。
struct StoredBubble: Codable, Equatable {
    var role: String
    var text: String
    var date: Date
}

/// 一段对话：标题 + 消息 + 时间戳。
struct Conversation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = "新对话"
    var bubbles: [StoredBubble] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var isEmpty: Bool { bubbles.isEmpty }

    /// 由气泡重建 Agent 可用的消息历史（仅 user / assistant 文本）。
    func agentMessages(model: String, api: String) -> [Message] {
        var out: [Message] = []
        for b in bubbles {
            let ts = Int(b.date.timeIntervalSince1970 * 1000)
            switch b.role {
            case "user":
                out.append(.user(UserMessage(content: b.text, timestamp: ts)))
            case "assistant":
                out.append(.assistant(AssistantMessage(
                    content: [.text(TextContent(text: b.text))],
                    api: api,
                    provider: api,
                    model: model,
                    stopReason: .stop,
                    timestamp: ts
                )))
            default:
                break
            }
        }
        return out
    }

    /// 用首条用户消息生成标题。
    static func derivedTitle(from bubbles: [StoredBubble]) -> String {
        guard let first = bubbles.first(where: { $0.role == "user" })?.text else { return "新对话" }
        let line = first.split(separator: "\n").first.map(String.init) ?? first
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "新对话" : String(trimmed.prefix(24))
    }
}

/// 会话列表的持久化（~/.config/myna/conversations.json）。
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [Conversation] = []
    @Published var currentID: UUID?

    private let path = NSString(string: "~/.config/myna/conversations.json").expandingTildeInPath
    private var pendingSave: DispatchWorkItem?

    private init() { load() }

    var current: Conversation? { conversations.first { $0.id == currentID } }

    // MARK: - 读写

    private func load() {
        guard let data = FileManager.default.contents(atPath: path) else {
            conversations = []
            return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        conversations = (try? dec.decode([Conversation].self, from: data)) ?? []
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
    }

    private func writeToDisk() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(conversations) else { return }
        FileManager.default.createFile(atPath: path, contents: data)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    // MARK: - 增删改

    @discardableResult
    func create(title: String = "新对话") -> Conversation {
        let c = Conversation(title: title)
        conversations.insert(c, at: 0)
        currentID = c.id
        scheduleSave()
        return c
    }

    func update(_ conversation: Conversation) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[idx] = conversation
        scheduleSave()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id }
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[idx].title = trimmed.isEmpty ? "新对话" : trimmed
        scheduleSave()
    }

    /// 全文搜索命中项。
    struct SearchHit: Identifiable, Equatable {
        let id: String
        let conversationID: UUID
        let title: String
        let role: String
        let snippet: String
        let bubbleIndex: Int
    }

    /// 在所有会话中做全文搜索。
    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 1 else { return [] }
        var hits: [SearchHit] = []
        for c in conversations {
            for (i, b) in c.bubbles.enumerated() where b.text.lowercased().contains(q) {
                hits.append(SearchHit(id: "\(c.id.uuidString)-#\(i)",
                                      conversationID: c.id,
                                      title: c.title,
                                      role: b.role,
                                      snippet: ConversationStore.snippet(b.text, query: q),
                                      bubbleIndex: i))
            }
        }
        return hits
    }

    /// 截取命中位置附近的片段。
    private static func snippet(_ text: String, query: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let lower = flat.lowercased()
        guard let range = lower.range(of: query) else {
            return String(flat.prefix(90))
        }
        let start = flat.index(range.lowerBound, offsetBy: -30, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
        var s = String(flat[start..<end])
        if start != flat.startIndex { s = "…" + s }
        if end != flat.endIndex { s += "…" }
        return s
    }

    /// 导入一段对话（作为新会话插入）。
    @discardableResult
    func insert(_ conversation: Conversation) -> Conversation {
        var c = conversation
        c.id = UUID()   // 避免与已有会话冲突
        conversations.insert(c, at: 0)
        currentID = c.id
        scheduleSave()
        return c
    }
}
