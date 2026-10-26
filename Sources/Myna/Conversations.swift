import Foundation
import PiKit

/// 持久化的一条消息（用于导出 / 多会话）。
struct StoredBubble: Codable, Equatable {
    var role: String
    var text: String
    var date: Date
    /// 用户消息附加的文件 / 文件夹；旧消息没有该字段。
    var attachments: [Attachment]?
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
    /// 累计未命中缓存的输入 token（按每次运行的服务端用量累加）。
    var inputTokens: Int = 0
    /// 累计输出 token。
    var outputTokens: Int = 0
    /// 累计缓存读取 token。旧版本没有该字段，读取时按 0 处理。
    var cacheReadTokens: Int = 0
    /// 累计缓存写入 token（Anthropic 等协议会用到；DeepSeek 通常为 0）。
    var cacheWriteTokens: Int = 0
    /// 累计模型请求数（一次工具往返算一次）。
    var requestCount: Int = 0
    /// 最近一轮运行的用量；用于重启后仍能在对话末尾显示上一轮命中率。
    var lastUsage: TokenUsage?
    /// 会话模式：normal / plan / goal / create。
    var mode: String = ChatMode.normal.rawValue
    /// 目标模式绑定的目标。
    var goal: Goal?
    /// 最近一次上下文压缩记录。
    var compaction: CompactionRecord?

    var isEmpty: Bool { bubbles.isEmpty }

    var chatMode: ChatMode {
        get { ChatMode(rawValue: mode) ?? .normal }
        set { mode = newValue.rawValue }
    }

    /// 本会话的累计用量；分项与 `lastUsage` 使用同一套口径。
    var totalUsage: TokenUsage {
        TokenUsage(input: inputTokens,
                   output: outputTokens,
                   cacheRead: cacheReadTokens,
                   cacheWrite: cacheWriteTokens,
                   requests: requestCount)
    }

    /// 显式列出编码键，工作目录使用 `working_directory`，与配置文件风格一致。
    enum CodingKeys: String, CodingKey {
        case id, title, bubbles, createdAt, updatedAt
        case workingDirectory = "working_directory"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case requestCount = "request_count"
        case lastUsage = "last_usage"
        case mode, goal, compaction
    }

    init(id: UUID = UUID(),
         title: String = "新对话",
         bubbles: [StoredBubble] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         workingDirectory: String = "",
         inputTokens: Int = 0,
         outputTokens: Int = 0,
         cacheReadTokens: Int = 0,
         cacheWriteTokens: Int = 0,
         requestCount: Int = 0,
         lastUsage: TokenUsage? = nil,
         mode: String = ChatMode.normal.rawValue,
         goal: Goal? = nil,
         compaction: CompactionRecord? = nil) {
        self.id = id
        self.title = title
        self.bubbles = bubbles
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workingDirectory = workingDirectory
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.requestCount = requestCount
        self.lastUsage = lastUsage
        self.mode = mode
        self.goal = goal
        self.compaction = compaction
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
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        requestCount = try c.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
        lastUsage = try c.decodeIfPresent(TokenUsage.self, forKey: .lastUsage)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ChatMode.normal.rawValue
        goal = try c.decodeIfPresent(Goal.self, forKey: .goal)
        compaction = try c.decodeIfPresent(CompactionRecord.self, forKey: .compaction)
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

    /// 落盘前清理 transcript：保留工具调用 / 工具结果 / 思考的结构，
    /// 只把图片块换成占位文本，避免 base64 让 conversations.json 膨胀。
    static func sanitizedTranscript(_ messages: [Message]) -> [Message] {
        func strip(_ blocks: [ContentBlock]) -> [ContentBlock] {
            blocks.map { block in
                if case .image = block {
                    return .text(TextContent(text: "[image omitted]"))
                }
                return block
            }
        }
        return messages.map { message in
            switch message {
            case .system:
                return message
            case .user(var user):
                if case .blocks(let blocks) = user.content {
                    user.content = .blocks(strip(blocks))
                }
                return .user(user)
            case .assistant(var assistant):
                assistant.content = strip(assistant.content)
                return .assistant(assistant)
            case .toolResult(var result):
                result.content = strip(result.content)
                return .toolResult(result)
            }
        }
    }

    /// 用首条用户消息生成标题。
    static func derivedTitle(from bubbles: [StoredBubble]) -> String {
        guard let first = bubbles.first(where: { $0.role == "user" })?.text else { return "新对话" }
        let line = first.split(separator: "\n").first.map(String.init) ?? first
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "新对话" : String(trimmed.prefix(24))
    }
}

/// 完整的 Agent transcript 单独落盘（`~/.config/myna/transcripts/<id>.json`）。
///
/// 不放进 `conversations.json`：工具调用 / 工具结果可能很大，混在一起会让
/// 每次气泡保存都重写整份会话文件。这里只在一轮结束、截断或清空时写一次。
enum TranscriptStore {
    static func path(for id: UUID) -> String {
        LocalResources.configDir + "/transcripts/" + id.uuidString + ".json"
    }

    static func load(_ id: UUID) -> [Message]? {
        guard let data = FileManager.default.contents(atPath: path(for: id)),
              let messages = try? JSONDecoder().decode([Message].self, from: data),
              !messages.isEmpty else { return nil }
        return messages
    }

    static func save(_ messages: [Message], for id: UUID) {
        let sanitized = Conversation.sanitizedTranscript(messages)
        guard !sanitized.isEmpty else {
            delete(id)
            return
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        // 单文件硬上限：避免极端长的工具输出把磁盘写满。
        guard data.count <= 16 * 1024 * 1024 else { return }
        let dir = (path(for: id) as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path(for: id)), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: path(for: id))
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(atPath: path(for: id))
    }
}

/// 会话列表的持久化（~/.config/myna/conversations.json）。
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [Conversation] = []
    /// 当前会话；变化时记住 id，重启后回到同一段对话，而不是最新创建的那段。
    @Published var currentID: UUID? {
        didSet {
            guard !suppressStateSave else { return }
            if let currentID {
                UserDefaults.standard.set(currentID.uuidString, forKey: Self.lastConversationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastConversationKey)
            }
        }
    }
    private static let lastConversationKey = "myna.lastConversationID"
    private var suppressStateSave = false

    /// 会话文件路径；可用 `MYNA_CONVERSATIONS` 覆盖（自检 / 多环境隔离）。
    private let path: String = {
        if let override = ProcessInfo.processInfo.environment["MYNA_CONVERSATIONS"],
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return NSString(string: "~/.config/myna/conversations.json").expandingTildeInPath
    }()
    private var pendingSave: DispatchWorkItem?

    private init() {
        load()
        if let raw = UserDefaults.standard.string(forKey: Self.lastConversationKey),
           let id = UUID(uuidString: raw),
           conversations.contains(where: { $0.id == id }) {
            currentID = id
        }
    }

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
    func create(title: String = "新对话", mode: String = ChatMode.normal.rawValue) -> Conversation {
        var c = Conversation(title: title)
        c.mode = mode
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

    /// 累加某个会话的 token 消费（由每次运行结束后调用）。
    func addTokenUsage(_ conversationID: UUID, usage: TokenUsage) {
        guard !usage.isEmpty else { return }
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[idx].inputTokens += usage.input
        conversations[idx].outputTokens += usage.output
        conversations[idx].cacheReadTokens += usage.cacheRead
        conversations[idx].cacheWriteTokens += usage.cacheWrite
        conversations[idx].requestCount += usage.requests
        conversations[idx].lastUsage = usage
        scheduleSave()
    }

    /// 全部会话的累计消费。
    var totalTokens: (input: Int, output: Int) {
        conversations.reduce(into: (0, 0)) { acc, c in
            acc.0 += c.inputTokens
            acc.1 += c.outputTokens
        }
    }

    /// 全部会话的累计用量（含缓存与请求次数）。
    var totalUsage: TokenUsage {
        conversations.reduce(into: TokenUsage()) { acc, c in
            acc.add(c.totalUsage)
        }
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
