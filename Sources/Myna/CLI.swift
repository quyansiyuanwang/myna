import Foundation
import PiKit

/// 命令行入口，供「快捷指令 / Siri」调用：`Myna ask "打开计算器"`
enum CLI {
    static func run(_ args: [String]) {
        switch args.first {
        case "ask":
            ask(args.dropFirst().joined(separator: " "))
        case "tool":
            // myna tool <name> [json-args]  —— 直接执行某个本机工具
            let rest = Array(args.dropFirst())
            guard let name = rest.first else { print("用法: myna tool <name> [json]"); return }
            let json = rest.count > 1 ? rest[1] : "{}"
            let a = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            print(ToolRunner.run(name: name, args: a))
        case "tools":
            // MCP 服务器异步启动，这里在 CLI 内做一次有界等待以便列出其工具
            MCPManager.shared.waitForStartup()
            for t in ToolRunner.catalog() { print("\(t.name)\t\(t.desc)") }
        case "models":
            listModels()
        case "merge-models":
            // 隐藏命令：把探测到的模型 id 合并进当前供应商（等价于探测弹窗确认）。
            mergeModels(Array(args.dropFirst()))
        case "config":
            // 隐藏命令：查看 / 切换当前供应商与模型（用于验证迁移与切换）。
            configCommand(Array(args.dropFirst()))
        case "profiles":
            // 隐藏命令：配置方案的文件级操作（用于验证方案覆盖全部设置）。
            profilesCommand(Array(args.dropFirst()))
        case "market-install":
            // 隐藏命令：从社区仓库安装技能 / MCP / 插件（用于验证与脚本化安装）。
            marketInstall(Array(args.dropFirst()))
        case "agent":
            runPackageAgent(args.dropFirst().joined(separator: " "))
        case "concurrency-check":
            // 隐藏命令：用真实 ChatModel 验证多会话并行运行互不干扰（供 CI / 本地验证）。
            concurrencyCheck()
        case "thinking-switch-check":
            // 隐藏命令：验证切换思考强度后对话上下文仍然保留。
            thinkingSwitchCheck()
        case "highlight":
            // 隐藏命令：校验代码高亮令牌器「去属性后逐字符还原」的不变式。
            highlightCommand(Array(args.dropFirst()))
        case "message-actions-check":
            // 隐藏命令：用真实 ChatModel 验证编辑 / 重发会截断会话并重建 Agent transcript。
            messageActionsCheck()
        case "help", "--help", "-h":
            print("""
            Myna 命令行
              Myna ask "问题"          调用大模型并执行本机操作，结果打印到 stdout
              echo "问题" | Myna ask   从标准输入读取问题
              Myna tool <name> [json]  直接执行某个本机工具
              Myna tools               列出全部工具
              Myna models              按当前配置探测可用模型并打印 id（不写入）
              Myna merge-models <id...> 把模型 id 合并进当前供应商（调试用）
              Myna agent "问题"        用 Swift 包 Agent 运行时对话（PiAI + PiAgentCore）
              Myna config [select 供应商 [模型]]  查看 / 切换当前供应商与模型（调试用）
              Myna config reasoning <等级>     设置当前模型的思考强度（调试用）
            """)
        default:
            ask(args.joined(separator: " "))
        }
    }

    static func ask(_ prompt: String) {
        var text = prompt
        var speak = false
        if text.hasPrefix("--speak ") {
            speak = true
            text = String(text.dropFirst("--speak ".count))
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { print("缺少输入"); return }

        let sem = DispatchSemaphore(value: 0)
        let agent = BuiltinAgent()
        agent.onTool = { name, result in
            FileHandle.standardError.write(Data("[tool] \(name) → \(result)\n".utf8))
        }
        Task {
            do {
                let answer = try await agent.ask(text)
                print(answer)
                if speak { ToolRunner.sh("say \(ToolRunner.q(answer))") }
            } catch {
                FileHandle.standardError.write(Data("错误: \(error.localizedDescription)\n".utf8))
            }
            sem.signal()
        }
        sem.wait()
    }

    /// 隐藏命令 `myna models`：按当前配置探测可用模型并打印 id。
    ///
    /// 与设置界面一致：探测只展示结果，不写入配置；是否添加由用户确认
    /// （可用 `myna merge-models` 模拟确认后的合并）。
    static func listModels() {
        let store = SettingsStore.shared
        let settings = store.settings
        guard !settings.apiKey.isEmpty else {
            FileHandle.standardError.write(Data("错误: 未配置 API Key（请在设置里填写）\n".utf8))
            return
        }
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let ids = try await ModelDiscovery.discover(baseURL: settings.baseURL,
                                                            apiKey: settings.apiKey,
                                                            api: settings.api)
                FileHandle.standardError.write(Data("探测到 \(ids.count) 个模型（未写入配置）\n".utf8))
                for id in ids { print(id) }
            } catch {
                FileHandle.standardError.write(Data("错误: \(error.localizedDescription)\n".utf8))
            }
            sem.signal()
        }
        sem.wait()
    }

    /// 隐藏命令 `myna merge-models <id> [id...]`：把指定模型 id 合并进当前供应商，
    /// 等价于设置界面探测弹窗里确认「添加选中」。
    static func mergeModels(_ args: [String]) {
        let store = SettingsStore.shared
        guard let pid = store.currentProviderID else {
            FileHandle.standardError.write(Data("错误: 当前没有选中的供应商\n".utf8))
            return
        }
        let names = args.flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            FileHandle.standardError.write(Data("用法: myna merge-models <id> [id...]\n".utf8))
            return
        }
        let added = store.mergeDiscoveredModels(names, intoProvider: pid)
        store.flush()
        let name = store.settings.providers.first { $0.id == pid }?.name ?? "?"
        print("已向「\(name)」添加 \(added) 个模型")
    }

    /// 隐藏命令 `myna config [select <供应商> [模型]]`。
    ///
    /// 不带参数时打印当前生效的扁平字段与供应商 JSON（用于验证迁移 / 切换）；
    /// `select` 会切到指定供应商（可选指定模型）并写回扁平字段。
    static func configCommand(_ rest: [String]) {
        let store = SettingsStore.shared
        if rest.first == "select" {
            guard rest.count >= 2 else {
                FileHandle.standardError.write(Data("用法: myna config select <供应商> [模型]\n".utf8))
                return
            }
            let providerName = rest[1]
            guard let provider = store.settings.providers.first(where: { $0.name == providerName }) else {
                FileHandle.standardError.write(Data("未找到供应商：\(providerName)\n".utf8))
                return
            }
            // 不带模型时只切供应商：没有模型则 active_model_id 置空。
            guard rest.count >= 3 else {
                store.selectProvider(id: provider.id)
                store.flush()
                print("已选择供应商 \(provider.name)（未指定模型）")
                print("active_provider_id=\(store.settings.activeProviderID?.uuidString ?? "nil")")
                print("active_model_id=\(store.settings.activeModelID?.uuidString ?? "nil")")
                printActiveFields(store.settings)
                return
            }
            let modelName = rest[2]
            guard let model = provider.models.first(where: { $0.name == modelName || $0.label == modelName }) else {
                FileHandle.standardError.write(Data("未找到模型：\(modelName)\n".utf8))
                return
            }
            store.selectModel(providerID: provider.id, modelID: model.id)
            store.flush()
            print("已选择 \(provider.name) / \(model.name)")
            print("active_provider_id=\(store.settings.activeProviderID?.uuidString ?? "nil")")
            print("active_model_id=\(store.settings.activeModelID?.uuidString ?? "nil")")
            printActiveFields(store.settings)
            return
        }
        if rest.first == "reasoning" {
            guard rest.count >= 2 else {
                FileHandle.standardError.write(Data("用法: myna config reasoning <等级>\n".utf8))
                return
            }
            // 与聊天顶栏 / 「推理」分区相同：同时写入当前模型与扁平字段。
            store.updateCurrentReasoning(effort: rest[1])
            store.flush()
            if let entry = store.currentModelEntry {
                print("model.name=\(entry.name)")
                print("model.reasoning_effort=\(entry.reasoningEffort)")
                print("model.thinking_levels=\(entry.thinkingLevels.joined(separator: ","))")
            }
            printActiveFields(store.settings)
            return
        }
        let s = store.settings
        printActiveFields(s)
        print("active_provider_id=\(s.activeProviderID?.uuidString ?? "nil")")
        print("active_model_id=\(s.activeModelID?.uuidString ?? "nil")")
        print("providers=")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s.providers), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func printActiveFields(_ s: AppSettings) {
        print("base_url=\(s.baseURL)")
        print("api=\(s.api)")
        print("api_key=\(s.apiKey.isEmpty ? "(空)" : "(已设置)")")
        print("model=\(s.model)")
        print("reasoning_effort=\(s.reasoningEffort)")
        print("thinking_budget=\(s.thinkingBudget)")
        print("max_tokens=\(s.maxTokens)")
        print("temperature=\(s.temperature)")
        print("max_history_turns=\(s.maxHistoryTurns)")
        print("unlimited_history_turns=\(s.unlimitedHistoryTurns)")
        print("effective_max_history_turns=\(s.effectiveMaxHistoryTurns)")
        print("subagent_provider_id=\(s.subagentProviderID?.uuidString ?? "nil")")
        print("subagent_model_id=\(s.subagentModelID?.uuidString ?? "nil")")
        print("subagent_max_rounds=\(s.subagentMaxRounds)")
        print("subagent_unlimited_rounds=\(s.subagentUnlimitedRounds)")
        print("subagent_timeout_seconds=\(s.subagentTimeoutSeconds)")
        print("subagent_unlimited_timeout=\(s.subagentUnlimitedTimeout)")
        print("subagent_max_parallel=\(s.subagentMaxParallel)")
        print("subagent_allow_recursion=\(s.subagentAllowRecursion)")
        print("subagent_model=\(s.subagentModelSettings().model)")
        print("effective_subagent_max_rounds=\(s.effectiveSubagentMaxRounds)")
        print("effective_subagent_timeout=\(s.effectiveSubagentTimeout)")
    }

    /// 隐藏命令 `myna profiles <list|save|apply|delete|export|import>`。
    static func profilesCommand(_ rest: [String]) {
        let store = SettingsStore.shared
        switch rest.first {
        case "list":
            for name in store.listProfiles() { print(name) }
        case "save":
            guard rest.count >= 2 else {
                FileHandle.standardError.write(Data("用法: myna profiles save <名称>\n".utf8))
                return
            }
            let ok = store.saveProfile(named: rest[1])
            if ok { store.flush() }
            print(ok ? "已保存方案 \(rest[1])" : "保存失败")
        case "apply":
            guard rest.count >= 2 else {
                FileHandle.standardError.write(Data("用法: myna profiles apply <名称>\n".utf8))
                return
            }
            if store.applyProfile(named: rest[1]) {
                store.flush()
                print("已应用方案 \(rest[1])")
                printActiveFields(store.settings)
            } else {
                FileHandle.standardError.write(Data("读取方案失败：\(rest[1])\n".utf8))
            }
        case "delete":
            guard rest.count >= 2 else { return }
            store.deleteProfile(named: rest[1])
            print("已删除方案 \(rest[1])")
        case "export":
            guard rest.count >= 3 else {
                FileHandle.standardError.write(Data("用法: myna profiles export <名称> <文件>\n".utf8))
                return
            }
            let ok = store.exportProfile(named: rest[1], to: URL(fileURLWithPath: rest[2]))
            print(ok ? "已导出方案 \(rest[1])" : "导出失败")
        case "import":
            guard rest.count >= 2 else {
                FileHandle.standardError.write(Data("用法: myna profiles import <文件> [名称]\n".utf8))
                return
            }
            let name = rest.count >= 3 ? rest[2] : ""
            let ok = store.importProfile(from: URL(fileURLWithPath: rest[1]), as: name)
            print(ok ? "已导入方案" : "导入失败（文件格式不正确）")
        default:
            print("用法: myna profiles <list|save|apply|delete|export|import>")
        }
    }

    /// 隐藏命令 `myna market-install <skill|mcp|plugin> <id>`。
    static func marketInstall(_ rest: [String]) {
        guard rest.count >= 2 else {
            FileHandle.standardError.write(Data("用法: myna market-install <skill|mcp|plugin> <id>\n".utf8))
            return
        }
        let kind = rest[0]
        let id = rest[1]
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                try await MarketplaceInstaller.installFromRegistry(kind: kind, id: id)
                print("已安装 \(kind) \(id)")
            } catch {
                FileHandle.standardError.write(Data("错误: \(error.localizedDescription)\n".utf8))
            }
            sem.signal()
        }
        sem.wait()
    }

    /// 使用 Swift 包运行时（PiAI + PiAgentCore）执行一次对话，运行期零 Node。
    static func runPackageAgent(_ prompt: String) {
        var text = prompt
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { print("缺少输入"); return }

        let settings = SettingsStore.shared.settings
        guard !settings.apiKey.isEmpty else {
            FileHandle.standardError.write(Data("错误: 未配置 API Key（请在设置里填写）\n".utf8))
            return
        }

        let sampling = SamplingSnapshot()
        sampling.update(settings)
        let agent = PackageRuntime.makeAgent(settings, sampling: sampling)
        let unsubscribe = agent.subscribe { event in
            switch event {
            case .messageUpdate(_, let update):
                if case .textDelta(let delta) = update {
                    FileHandle.standardOutput.write(Data(delta.utf8))
                }
            case .toolExecutionStart(_, let name, let arguments):
                let args = PackageRuntime.describe(arguments)
                FileHandle.standardError.write(Data("[tool] \(name)\(args.isEmpty ? "" : " " + args)\n".utf8))
            case .toolExecutionEnd(_, let name, _, let isError):
                FileHandle.standardError.write(Data("[tool] \(name) \(isError ? "error" : "ok")\n".utf8))
            default:
                break
            }
        }

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                try await agent.prompt(text)
            } catch {
                FileHandle.standardError.write(Data("错误: \(error.localizedDescription)\n".utf8))
            }
            sem.signal()
        }
        sem.wait()
        unsubscribe()
        print("")
    }

    // MARK: - 并发自检
    /// 隐藏命令 `myna concurrency-check`：用真实 ``ChatModel`` 同时驱动两个会话，
    /// 验证后台运行互不干扰、结果写入各自会话，以及并行上限的淘汰策略。
    static func concurrencyCheck() {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await runConcurrencyCheck()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(180)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() > deadline {
                box.value = "FAIL\n  [!!] 超时（180s）"
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        print(box.value)
        if !box.value.hasPrefix("PASS") { exit(1) }
    }

    /// 非主线程访问的结果容器（主 actor 写入后由 CLI 线程读取）。
    final class ResultBox: @unchecked Sendable {
        var value = ""
    }

    @MainActor
    private static func runConcurrencyCheck() async -> String {
        let settingsStore = SettingsStore.shared
        let store = ConversationStore.shared
        let originalLimit = settingsStore.settings.maxParallelRuns
        let originalBackground = settingsStore.settings.backgroundRuns
        settingsStore.settings.backgroundRuns = true
        settingsStore.settings.maxParallelRuns = 3

        var lines: [String] = []
        var ok = true
        func check(_ cond: Bool, _ msg: String) {
            lines.append((cond ? "  [ok] " : "  [!!] ") + msg)
            if !cond { ok = false }
        }

        let model = ChatModel()
        let tokenA = "AA11"
        let tokenB = "BB22"

        // ---- 阶段一：两个会话并行 ----
        model.newConversation()
        let idA = store.currentID
        model.input = "请只回复这四个字符，不要包含任何其他字符：\(tokenA)"
        model.send()
        model.newConversation()
        let idB = store.currentID
        model.input = "请只回复这四个字符，不要包含任何其他字符：\(tokenB)"
        model.send()

        lines.append("阶段一 A=\(short(idA)) B=\(short(idB)) 同时运行=\(model.runningConversations.count)")
        if let idA, let idB {
            check(Set([idA, idB]).isSubset(of: model.runningConversations), "两个会话同时在运行（并发）")
        } else {
            check(false, "创建两个会话")
        }

        var deadline = Date().addingTimeInterval(150)
        while !model.runningConversations.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        check(model.runningConversations.isEmpty, "两个会话都已完成")

        if let idA, let idB {
            let a = store.conversations.first { $0.id == idA }
            let b = store.conversations.first { $0.id == idB }
            let textA = assistantText(a)
            let textB = assistantText(b)
            lines.append("  A 回复: \(textA)")
            lines.append("  B 回复: \(textB)")
            check(textA.contains(tokenA) && !textA.contains(tokenB), "A 的回复写入会话 A，未混入 B")
            check(textB.contains(tokenB) && !textB.contains(tokenA), "B 的回复写入会话 B，未混入 A")
            check(!cancelled(a), "A 未被取消")
            check(!cancelled(b), "B 未被取消")
        }

        // ---- 阶段二：并行上限淘汰最旧会话 ----
        settingsStore.settings.maxParallelRuns = 1
        model.newConversation()
        let idC = store.currentID
        model.input = "请只回复：\(tokenA)"
        model.send()
        model.newConversation()
        let idD = store.currentID
        model.input = "请只回复：\(tokenB)"
        model.send()
        check(model.runningConversations.count <= 1, "并行上限为 1 时最多一个会话在运行")

        deadline = Date().addingTimeInterval(150)
        while !model.runningConversations.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if let idC {
            check(cancelled(store.conversations.first { $0.id == idC }), "超出并行上限后最旧的会话收到停止提示")
        }
        if let idD {
            check(assistantText(store.conversations.first { $0.id == idD }).contains(tokenB), "最新会话正常完成")
        }

        // ---- 清理 ----
        for id in [idA, idB, idC, idD].compactMap({ $0 }) {
            model.deleteConversation(id)
        }
        settingsStore.settings.maxParallelRuns = originalLimit
        settingsStore.settings.backgroundRuns = originalBackground
        settingsStore.flush()
        store.flush()

        return ([ok ? "PASS" : "FAIL"] + lines).joined(separator: "\n")
    }

    private static func short(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(8)) } ?? "nil"
    }

    private static func assistantText(_ c: Conversation?) -> String {
        (c?.bubbles ?? []).filter { $0.role == "assistant" }.map(\.text).joined(separator: " ")
    }

    private static func cancelled(_ c: Conversation?) -> Bool {
        (c?.bubbles ?? []).contains { $0.role == "error" && $0.text.contains("并行上限") }
    }

    // MARK: - 思考强度切换自检

    /// 隐藏命令 `myna thinking-switch-check`：验证在对话中切换思考强度后，
    /// Agent 重建但上下文仍保留。
    static func thinkingSwitchCheck() {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await runThinkingSwitchCheck()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(180)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() > deadline {
                box.value = "FAIL\n  [!!] 超时（180s）"
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        print(box.value)
        if !box.value.hasPrefix("PASS") { exit(1) }
    }

    @MainActor
    private static func runThinkingSwitchCheck() async -> String {
        let settingsStore = SettingsStore.shared
        let store = ConversationStore.shared
        let model = ChatModel()
        var lines: [String] = []
        var ok = true
        func check(_ cond: Bool, _ msg: String) {
            lines.append((cond ? "  [ok] " : "  [!!] ") + msg)
            if !cond { ok = false }
        }
        // 自检结束后恢复用户原本的等级。
        let originalEffort = settingsStore.settings.reasoningEffort

        // 保证当前模型声明了可用于切换的等级（不改动用户原本的等级，仅本地测试）。
        if let pid = settingsStore.currentProviderID, let mid = settingsStore.currentModelID,
           let pi = settingsStore.settings.providers.firstIndex(where: { $0.id == pid }),
           let mi = settingsStore.settings.providers[pi].models.firstIndex(where: { $0.id == mid }) {
            let levels = settingsStore.settings.providers[pi].models[mi].thinkingLevels
            lines.append("  可用等级: \(levels.isEmpty ? "(空)" : levels.joined(separator: ","))")
        }

        let token = "ZQ7"
        model.newConversation()
        let id = store.currentID
        model.input = "请只回复这三个字符，不要包含任何其他字符：\(token)"
        model.send()
        var deadline = Date().addingTimeInterval(150)
        while !model.runningConversations.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let first = lastAssistantText(store.conversations.first { $0.id == id })
        lines.append("  第一轮: \(first)")
        check(first.contains(token), "第一轮得到 \(token)")

        // 切换思考等级：与聊天顶栏切换走同一条 store 路径。
        settingsStore.updateCurrentReasoning(effort: "high")
        lines.append("  切换后 flat.reasoning_effort=\(settingsStore.settings.reasoningEffort)")
        check(settingsStore.settings.reasoningEffort == "high", "切换写入扁平字段")

        model.input = "我刚才让你只回复的三个字符是什么？只回复那三个字符，不要解释。"
        model.send()
        deadline = Date().addingTimeInterval(150)
        while !model.runningConversations.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let second = lastAssistantText(store.conversations.first { $0.id == id })
        lines.append("  第二轮: \(second)")
        check(second.contains(token), "切换思考等级后仍记得上一轮内容（上下文保留）")

        if let id { model.deleteConversation(id) }
        settingsStore.updateCurrentReasoning(effort: originalEffort)
        settingsStore.flush()
        store.flush()
        return ([ok ? "PASS" : "FAIL"] + lines).joined(separator: "\n")
    }

    private static func lastAssistantText(_ c: Conversation?) -> String {
        (c?.bubbles ?? []).last(where: { $0.role == "assistant" })?.text ?? ""
    }

    // MARK: - 代码高亮自检

    /// 隐藏命令 `myna highlight <lang> [file| -] [--dump]`。
    ///
    /// 打印识别到的语言与「去属性后是否逐字符还原」的结论；`--dump` 时输出
    /// 每个词法区间，便于人工核对。不一致时以非零码退出。
    static func highlightCommand(_ rest: [String]) {
        var dump = false
        var positional: [String] = []
        for a in rest {
            if a == "--dump" { dump = true } else { positional.append(a) }
        }
        guard let lang = positional.first else {
            FileHandle.standardError.write(Data("用法: myna highlight <lang> [file|-] [--dump]\n".utf8))
            return
        }
        let path = positional.count >= 2 ? positional[1] : "-"
        let data: Data
        if path == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else if let d = FileManager.default.contents(atPath: path) {
            data = d
        } else {
            FileHandle.standardError.write(Data("无法读取文件：\(path)\n".utf8))
            exit(1)
        }
        guard let code = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("文件不是 UTF-8 文本\n".utf8))
            exit(1)
        }
        let detected = SyntaxLanguage.detect(lang)
        let attr = SyntaxHighlighter.highlight(code, language: lang, dark: false)
        let exact = String(attr.characters) == code
        print("language=\(detected.rawValue) display=\(detected.displayName) chars=\(code.count) roundtrip=\(exact ? "exact" : "MISMATCH")")
        if dump {
            for seg in SyntaxHighlighter.segments(code, language: lang) {
                print("\(seg.kind)\t\(seg.text)")
            }
        }
        if !exact { exit(1) }
    }

    // MARK: - 消息操作自检

    /// 隐藏命令 `myna message-actions-check`：用真实 ``ChatModel`` 验证
    /// 用户消息「编辑并重发」与助手消息「重发」会截断会话、重建 transcript，
    /// 且模型不再记得被删除轮次里的信息。
    static func messageActionsCheck() {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await runMessageActionsCheck()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(300)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() > deadline {
                box.value = "FAIL\n  [!!] 超时（300s）"
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        print(box.value)
        if !box.value.hasPrefix("PASS") { exit(1) }
    }

    @MainActor
    private static func runMessageActionsCheck() async -> String {
        let store = ConversationStore.shared
        let model = ChatModel()
        var lines: [String] = []
        var ok = true
        func check(_ cond: Bool, _ msg: String) {
            lines.append((cond ? "  [ok] " : "  [!!] ") + msg)
            if !cond { ok = false }
        }

        model.newConversation()
        guard let id = store.currentID else { return "FAIL\n  [!!] 未创建会话" }
        lines.append("会话 id=\(short(id))")

        // 第一轮：普通问答，便于后续定位助手气泡。
        await drive(model, "请只回复：好的")
        let firstUser = model.bubbles.first { $0.role == .user }?.id
        check(firstUser != nil, "存在首条用户消息")

        // 第二轮：引入一个只存在于本轮的暗号。
        let secret = "芝麻开门"
        await drive(model, "请记住「\(secret)」这几个字，然后只回复：记住了")
        let secretUser = model.bubbles.last { $0.role == .user && $0.text.contains(secret) }?.id
        check(secretUser != nil, "第二条用户消息包含暗号")

        // 第三轮：模型应能回忆暗号。
        await drive(model, "我刚才让你记住的那几个字是什么？只回复那几个字。")
        let recall = lastAssistantText(store.conversations.first { $0.id == id })
        lines.append("  编辑前回忆：\(recall)")
        check(recall.contains(secret), "编辑前模型记得暗号")

        // 编辑并重发：删除暗号。
        if let secretUser {
            let before = model.bubbles.count
            model.editAndResend(bubbleID: secretUser, text: "请只回复：记住了")
            await waitIdle(model, id)
            let after = store.conversations.first { $0.id == id }
            let texts = (after?.bubbles ?? []).map(\.text).joined(separator: "\n")
            check(!texts.contains(secret), "截断后会话里不再包含暗号原文")
            check((after?.bubbles.count ?? 0) < before, "被删除轮次的气泡已从会话消失（\(before) → \(after?.bubbles.count ?? 0)）")
            // transcript 同步：Agent 内部消息里也不能含暗号。
            let transcript = await model.transcriptText(for: id)
            check(!transcript.contains(secret), "Agent transcript 与截断后的会话一致（不含暗号）")
            lines.append("  transcript 条目/字符数：\(await model.transcriptLineCount(for: id))/\(transcript.count)")
        } else {
            check(false, "定位暗号消息")
        }

        // 再问一次：模型不应再知道暗号。
        await drive(model, "我刚才让你记住的那几个字是什么？如果你没有收到过任何暗号，请只回复：无")
        let afterRecall = lastAssistantText(store.conversations.first { $0.id == id })
        lines.append("  编辑后回忆：\(afterRecall)")
        check(!afterRecall.contains(secret), "编辑后模型不再记得被删除的暗号")

        // 助手消息重发：找到最后一条助手消息，重发后应出现新的助手回答。
        if let assistant = model.bubbles.last(where: { $0.role == .assistant })?.id {
            let beforeAssistant = lastAssistantText(store.conversations.first { $0.id == id })
            model.resend(bubbleID: assistant)
            await waitIdle(model, id)
            let afterAssistant = lastAssistantText(store.conversations.first { $0.id == id })
            lines.append("  助手重发前：\(shortText(beforeAssistant))")
            lines.append("  助手重发后：\(shortText(afterAssistant))")
            check(!afterAssistant.isEmpty, "助手重发后得到新的回答")
            check(model.bubbles.last?.role == .assistant, "重发后最后一条是助手消息")
        } else {
            check(false, "定位最后一条助手消息")
        }

        model.deleteConversation(id)
        store.flush()
        return ([ok ? "PASS" : "FAIL"] + lines).joined(separator: "\n")
    }

    /// 通过 ChatModel 发送一段输入并等待该会话空闲。
    @MainActor
    private static func drive(_ model: ChatModel, _ text: String) async {
        model.input = text
        model.send()
        await waitIdle(model, model.currentConversationID)
    }

    @MainActor
    private static func waitIdle(_ model: ChatModel, _ id: UUID?) async {
        guard let id else { return }
        let deadline = Date().addingTimeInterval(150)
        while model.runningConversations.contains(id), Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private static func shortText(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return String(flat.prefix(40))
    }
}
