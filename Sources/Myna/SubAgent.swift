import Foundation
import PiKit

/// 子代理运行器。
///
/// 把模型交办的独立任务交给一个全新的 `Agent`：拥有独立的系统提示、上下文与工具集，
/// 运行到完成后只把最终文本返回主代理。子代理默认禁用 `run_subagent` /
/// `run_subagents`，避免递归派生新的子代理；可在设置中开启 `subagentAllowRecursion`。
///
/// 模型来源、超时与轮数由设置决定：可跟随主模型，也可指定供应商 / 模型；
/// 「无限制」仍有内部安全上限，保证不会真正无界。
///
/// 同时提供异步 API（`PiKit.FunctionTool` 路径）与有界阻塞 API
/// （`ToolRunner.run` 同步路径）。阻塞实现使用信号量加超时，绝不会无限期挂起
/// 主线程，思路与 ``MCPManager/callSync(namespaced:arguments:timeout:)`` 一致。
struct SubAgentRunner: Sendable {

    /// 子代理默认系统提示词。
    static let defaultSystemPrompt = """
    你是一个独立的子代理，负责专注完成主代理交给你的单个任务。
    规则：
    1. 需要本机操作时直接调用工具，不要臆造或假设工具结果。
    2. 不要向用户提问，独立完成任务；缺少必要信息时给出合理结论并说明假设。
    3. 完成后只输出简洁的最终结果（必要时列出关键步骤与结论），不要寒暄或复述过程。
    """

    /// 一次子代理请求。
    struct Request: Sendable {
        var task: String
        var systemPrompt: String?
        var tools: [String]?
        var maxRounds: Int?
        var timeout: TimeInterval?
    }

    let settings: AppSettings
    /// 父会话解析好的工作目录；子代理继承它（为空 = 应用默认）。
    let workingDirectory: String?

    init(settings: AppSettings = SettingsStore.shared.settings, workingDirectory: String? = nil) {
        self.settings = settings
        self.workingDirectory = workingDirectory
    }

    // MARK: - 参数解析（供 ToolRunner / FunctionTool 共用）

    /// 同步路径：供 `ToolRunner.run` 使用。
    static func handle(_ name: String, args: [String: Any], workingDirectory: String? = nil) -> String {
        let runner = SubAgentRunner(workingDirectory: workingDirectory)
        if name == "run_subagents" {
            return runner.runParallelBlocking(tasks: stringArray(args["tasks"]) ?? [],
                                              systemPrompt: args["system_prompt"] as? String,
                                              tools: stringArray(args["tools"]))
        }
        return runner.runBlocking(request(from: args))
    }

    /// 异步路径：供 `ToolRunner.packageTools` 使用。
    static func handleAsync(_ name: String, args: [String: Any], workingDirectory: String? = nil) async -> String {
        let runner = SubAgentRunner(workingDirectory: workingDirectory)
        if name == "run_subagents" {
            return await runner.runParallel(tasks: stringArray(args["tasks"]) ?? [],
                                            systemPrompt: args["system_prompt"] as? String,
                                            tools: stringArray(args["tools"]))
        }
        return await runner.run(request(from: args))
    }

    static func request(from args: [String: Any]) -> Request {
        Request(task: args["task"] as? String ?? "",
                systemPrompt: args["system_prompt"] as? String,
                tools: stringArray(args["tools"]),
                maxRounds: intValue(args["max_rounds"]),
                timeout: doubleValue(args["timeout_seconds"]))
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    // MARK: - 异步 API

    /// 运行单个子代理直到完成，返回最终文本（失败时返回可读的错误信息）。
    func run(_ request: Request) async -> String {
        let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return "子代理任务为空。" }

        let timeout = effectiveTimeout(request.timeout)
        let rounds = effectiveRounds(request.maxRounds)
        let prompt = normalizedPrompt(request.systemPrompt)
        let tools = makeTools(request.tools)

        let sampling = SamplingSnapshot()
        // 模型来源：未指定或已失效时回退主模型（见 AppSettings.subagentModelSettings）。
        let modelSettings = settings.subagentModelSettings()
        sampling.update(modelSettings)
        let agent = PackageRuntime.makeAgent(modelSettings,
                                             sampling: sampling,
                                             systemPrompt: prompt,
                                             maxToolRounds: rounds,
                                             tools: tools,
                                             workingDirectory: workingDirectory)
        do {
            try await withTimeout(timeout) { try await agent.prompt(task) }
        } catch is SubAgentTimeoutError {
            await agent.abort()
            return "子代理执行超时（\(Int(timeout)) 秒）。"
        } catch is CancellationError {
            await agent.abort()
            return "子代理已取消。"
        } catch {
            await agent.abort()
            return "子代理执行失败：\(error.localizedDescription)"
        }
        let answer = PackageRuntime.finalAnswer(in: await agent.transcript)
        return answer.isEmpty ? "（子代理没有返回内容）" : answer
    }

    /// 并行运行多个子代理，按 `subagent_max_parallel` 控制并发，
    /// 返回带分隔符的结果文本。
    func runParallel(tasks: [String],
                     systemPrompt: String?,
                     tools: [String]?) async -> String {
        let items = tasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return "没有需要执行的子任务。" }

        let limit = max(1, settings.subagentMaxParallel)
        var outputs: [String] = []
        var start = 0
        while start < items.count {
            let end = min(items.count, start + limit)
            let slice = Array(items[start..<end])
            let base = start
            let batch = await withTaskGroup(of: (Int, String).self) { group -> [(Int, String)] in
                for (offset, item) in slice.enumerated() {
                    let request = Request(task: item, systemPrompt: systemPrompt, tools: tools)
                    group.addTask { [self] in
                        (base + offset, await run(request))
                    }
                }
                var collected: [(Int, String)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }
            }
            outputs.append(contentsOf: batch.map(\.1))
            start = end
        }

        var sections: [String] = []
        for (index, item) in items.enumerated() {
            let result = index < outputs.count ? outputs[index] : "（无结果）"
            sections.append("=== 子代理 \(index + 1) ===\n任务：\(item)\n结果：\(result)")
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    // MARK: - 有界阻塞 API

    func runBlocking(_ request: Request) -> String {
        let timeout = effectiveTimeout(request.timeout)
        let result = SubAgentRunner.blocking(wait: timeout + 20) { [self] in
            await run(request)
        }
        return result ?? "子代理执行超时（\(Int(timeout)) 秒）。"
    }

    func runParallelBlocking(tasks: [String],
                             systemPrompt: String?,
                             tools: [String]?) -> String {
        let timeout = effectiveTimeout(nil)
        let count = tasks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let limit = max(1, settings.subagentMaxParallel)
        let batches = max(1, (count + limit - 1) / limit)
        let result = SubAgentRunner.blocking(wait: Double(batches) * timeout + 20) { [self] in
            await runParallel(tasks: tasks, systemPrompt: systemPrompt, tools: tools)
        }
        return result ?? "子代理执行超时（\(Int(timeout)) 秒）。"
    }

    /// 在后台任务中执行异步操作，最多等待 `seconds` 秒；超时返回 nil，
    /// 不会无限期阻塞调用线程。
    private static func blocking<T: Sendable>(
        wait seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) -> T? {
        let box = SubAgentResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.set(await operation())
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + max(1, seconds)) == .timedOut { return nil }
        return box.get()
    }

    // MARK: - 内部辅助

    /// 让异步 `prompt` 在 `seconds` 秒后超时（抛 ``SubAgentTimeoutError``）。
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                throw SubAgentTimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SubAgentTimeoutError() }
            return result
        }
    }

    /// 解析子代理超时：显式请求值优先，其次设置；`<= 0` 使用安全上限。
    private func effectiveTimeout(_ requested: TimeInterval?) -> TimeInterval {
        if let requested {
            if requested <= 0 { return AppSettings.unlimitedSubagentTimeoutCap }
            return min(max(requested, 5), AppSettings.unlimitedSubagentTimeoutCap)
        }
        return settings.effectiveSubagentTimeout
    }

    /// 解析子代理轮数：显式请求值优先，其次设置；`<= 0` 使用安全上限。
    private func effectiveRounds(_ requested: Int?) -> Int {
        if let requested {
            if requested <= 0 { return AppSettings.unlimitedToolRoundCap }
            return min(requested, AppSettings.unlimitedToolRoundCap)
        }
        return settings.effectiveSubagentMaxRounds
    }

    private func normalizedPrompt(_ custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SubAgentRunner.defaultSystemPrompt : trimmed
    }

    /// 构造子代理工具集：继承 `disabledTools`；默认强制排除递归工具，
    /// 仅在 `subagentAllowRecursion` 打开时保留（防止递归与费用失控）。
    private func makeTools(_ allow: [String]?) -> [any AgentTool] {
        var disabled = settings.disabledTools
        if !settings.subagentAllowRecursion {
            for name in ToolRunner.subAgentExcluded where !disabled.contains(name) {
                disabled.append(name)
            }
        }
        let visible = Set(ToolRunner.definitions(disabled: disabled).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        })
        var only: [String]?
        if let allow {
            only = allow.filter { visible.contains($0) }
        }
        return ToolRunner.packageTools(disabled: disabled, only: only, workingDirectory: workingDirectory)
    }
}

/// 子代理超时错误。
struct SubAgentTimeoutError: Error {}

/// 跨线程传递异步结果的小盒子。
private final class SubAgentResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
