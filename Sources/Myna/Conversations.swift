import Foundation
import PiKit

/// 持久化的一条消息（用于导出 / 多会话）。
struct StoredBubble: Codable, Equatable {
    var role: String
    var text: String
    var date: Date
}

/// 一段对话：标题 + 消息 + 时间戳 + 工作目录。
///
/// ``workingDirectory`` 属于会话本身：为空表示跟随
/// ``AppSettings/workingDirectory``（应用默认），仍为空则使用用户主目录。
struct Conversation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = "新对话"
    var bubbles: [StoredBubble] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// 会话自己的工作目录；空 = 使用应用默认（设置里的「默认工作目录」）。
    var workingDirectory: String = ""

    var isEmpty: Bool { bubbles.isEmpty }

    /// 显式列出编码键，工作目录使用 `working_directory`，与配置文件风格一致。
    enum CodingKeys: String, CodingKey {
        case id, title, bubbles, createdAt, updatedAt
        case workingDirectory = "working_directory"
    }

    init(id: UUID = UUID(),
         title: String = "新对话",
         bubbles: [StoredBubble] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         workingDirectory: String = "") {
        self.id = id
        self.title = title
        self.bubbles = bubbles
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workingDirectory = workingDirectory
    }

    /// 旧版会话文件没有 `working_directory` 字段，缺失时回落为空（应用默认）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "新对话"
        bubbles = try c.decodeIfPresent([StoredBubble].self, forKey: .bubbles) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
    }

    /// 由气泡重建 Agent 可用的消息历史（仅 user / assistant 文本）。
    func agentMessages(model: String, api: String) -> [Message] {
        Conversation.agentMessages(from: bubbles, model: model, api: api)
    }

    /// 由任意一组气泡构建 Agent 消息列表（供截断后重建 transcript 复用）。
    static func agentMessages(from bubbles: [StoredBubble], model: String, api: String) -> [Message] {
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

    /// 会话文件路径；可用 `MYNA_CONVERSATIONS` 覆盖（自检 / 多环境隔离）。
    private let path: String = {
        if let override = ProcessInfo.processInfo.environment["MYNA_CONVERSATIONS"],
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return NSString(string: "~/.config/myna/conversations.json").expandingTildeInPath
    }()
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

    /// 从某个对话的第 `index` 条消息处创建分支（**包含**该条），原对话保持不变。
    ///
    /// 分支拥有自己的气泡与工作目录，后续对话互不影响；用于「保留上文、换个方向重来」。
    @discardableResult
    func branch(from id: UUID, upto index: Int) -> Conversation? {
        guard let source = conversations.first(where: { $0.id == id }),
              index >= 0, index < source.bubbles.count else { return nil }
        let kept = Array(source.bubbles.prefix(index + 1))
        let now = Date()
        let branch = Conversation(
            title: Self.branchTitle(from: source.title),
            bubbles: kept,
            createdAt: now,
            updatedAt: now,
            workingDirectory: source.workingDirectory
        )
        conversations.insert(branch, at: 0)
        currentID = branch.id
        scheduleSave()
        return branch
    }

    /// 分支标题：「原标题 · 分支」，重复分支时递增编号。
    private static func branchTitle(from base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? "新对话" : trimmed
        return "\(stem) · 分支"
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

    /// 设置会话自己的工作目录；传空字符串表示回到应用默认。
    func setWorkingDirectory(_ id: UUID, to directory: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversations[idx].workingDirectory != trimmed else { return }
        conversations[idx].workingDirectory = trimmed
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
