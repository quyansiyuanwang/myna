import Foundation
import PiKit
import SwiftUI

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
        case "branch-check":
            // 隐藏命令：断言对话分支的截取范围、工作目录继承与原对话不受影响。
            MainActor.assumeIsolated { branchCheck() }
        case "mcp-check":
            // 隐藏命令：断言 MCP 服务器配置的增 / 查 / 改 / 删往返（用临时配置文件）。
            mcpCheck()
        case "search-check":
            // 隐藏命令：断言搜索请求构造、响应解析、错误映射与未配置提示（离线可跑）。
            searchCheck()
        case "proxy-check":
            // 隐藏命令：断言代理字典构造（http/https/socks5、认证、绕过列表）。
            proxyCheck()
        case "markdown-check":
            // 隐藏命令：逐项断言 Markdown 块级解析与内联样式（供本地 / CI 验证渲染）。
            markdownCheck()
        case "message-actions-check":
            // 隐藏命令：用真实 ChatModel 验证编辑 / 重发会截断会话并重建 Agent transcript。
            messageActionsCheck()
        case "working-dir-check":
            // 隐藏命令：验证工作目录按会话隔离、回退链、持久化 / 导出导入与签名重建。
            workingDirCheck()
        case "update-check":
            // 隐藏命令：打印当前 / 最新版本与比较结果，并跑纯版本比较断言。
            updateCheck()
        case "conversation-dir":
            // 隐藏命令：跨进程验证会话工作目录的持久化。
            conversationDirCommand(Array(args.dropFirst()))
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
              Myna markdown-check             校验 Markdown 渲染的块级 / 内联样式（调试用）
              Myna working-dir-check          验证工作目录按会话隔离与回退链（调试用）
              Myna update-check               检查更新并自检版本比较（调试用）
              Myna conversation-dir set|get|clear  读写 / 清理会话工作目录（调试用）
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

    // MARK: - Markdown 渲染自检

    /// 隐藏命令 `myna markdown-check`：用固定样本走一遍块级解析 + 内联样式，
    /// 逐项断言标题、粗体、行内代码、列表、引用、表格、代码块等渲染特征。
    /// 断言 MCP 服务器配置的增删改查往返。
    static func mcpCheck() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1; print("PASS \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
            else { fail += 1; print("FAIL \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
        }
        let tmp = NSTemporaryDirectory() + "myna-mcp-check-\(UUID().uuidString).json"
        setenv("MYNA_MCP_CONFIG", tmp, 1)
        defer { unsetenv("MYNA_MCP_CONFIG"); try? FileManager.default.removeItem(atPath: tmp) }

        let manager = MCPManager.shared
        check("初始为空", manager.configuredServers().isEmpty)

        let cfg = MCPServerConfig(command: "npx",
                                  args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                                  env: ["FOO": "bar"])
        check("新增服务器", manager.upsertServer(name: "fs", config: cfg))
        let list = manager.configuredServers()
        check("列表含该服务器", list.count == 1 && list[0].name == "fs")
        check("命令往返", list.first?.config.command == "npx")
        check("参数往返", list.first?.config.args?.count == 3)
        check("环境变量往返", list.first?.config.env?["FOO"] == "bar")

        var updated = cfg
        updated.command = "uvx"
        check("覆盖同名服务器", manager.upsertServer(name: "fs", config: updated))
        check("覆盖后命令已变", manager.configuredServers().first?.config.command == "uvx")

        check("空名称被拒绝", !manager.upsertServer(name: "  ", config: cfg))
        check("删除服务器", manager.removeServer(name: "fs"))
        check("删除后为空", manager.configuredServers().isEmpty)
        check("删除不存在的服务器返回 false", !manager.removeServer(name: "nope"))

        // 文件结构应保持 {"servers": {...}} 且权限 0600
        if let data = FileManager.default.contents(atPath: tmp),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            check("文件结构含 servers 键", obj["servers"] != nil)
        } else {
            check("文件结构含 servers 键", false, "无法读取")
        }
        let perms = (try? FileManager.default.attributesOfItem(atPath: tmp)[.posixPermissions] as? Int) ?? 0
        check("文件权限 0600", perms == 0o600, String(perms, radix: 8))

        print("结果: \(fail == 0 ? "全部通过" : "有 \(fail) 项失败")（MCP 配置自检，通过 \(pass)/\(pass+fail)）")
    }

    /// 断言对话分支行为。
    @MainActor
    static func branchCheck() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1; print("PASS \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
            else { fail += 1; print("FAIL \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
        }
        let tmp = NSTemporaryDirectory() + "myna-branch-check-\(UUID().uuidString).json"
        setenv("MYNA_CONVERSATIONS", tmp, 1)
        defer { unsetenv("MYNA_CONVERSATIONS"); try? FileManager.default.removeItem(atPath: tmp) }

        let store = ConversationStore.shared
        // 用公开 API 构造：新建 → 写入气泡与工作目录
        var source = store.create(title: "原始对话")
        source.bubbles = (0..<5).map { i in
            StoredBubble(role: i % 2 == 0 ? "user" : "assistant", text: "消息 \(i)", date: Date())
        }
        source.workingDirectory = "/tmp/project"
        store.update(source)

        let before = store.conversations.count
        let branch = store.branch(from: source.id, upto: 2)
        check("分支已创建", branch != nil)
        check("分支含该条及之前共 3 条", branch?.bubbles.count == 3, "\(branch?.bubbles.count ?? -1)")
        check("分支内容正确", branch?.bubbles.map(\.text) == ["消息 0", "消息 1", "消息 2"])
        check("分支继承工作目录", branch?.workingDirectory == "/tmp/project")
        check("分支标题带后缀", branch?.title == "原始对话 · 分支", branch?.title ?? "-")
        check("原对话气泡未被改动",
              store.conversations.first(where: { $0.id == source.id })?.bubbles.count == 5)
        check("会话总数 +1", store.conversations.count == before + 1)
        check("已切换到分支", store.currentID == branch?.id)

        if var b = branch {
            b.bubbles.append(StoredBubble(role: "user", text: "新消息", date: Date()))
            store.update(b)
        }
        check("分支独立：追加不影响原对话",
              store.conversations.first(where: { $0.id == source.id })?.bubbles.count == 5
              && store.conversations.first(where: { $0.id == branch?.id })?.bubbles.count == 4)
        check("越界下标被拒绝", store.branch(from: source.id, upto: 99) == nil)
        check("负下标被拒绝", store.branch(from: source.id, upto: -1) == nil)

        print("结果: \(fail == 0 ? "全部通过" : "有 \(fail) 项失败")（对话分支自检，通过 \(pass)/\(pass+fail)）")
    }

    // MARK: - 网络搜索 / 代理自检

    /// 断言搜索请求构造、响应解析、错误映射与未配置提示。
    static func searchCheck() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1; print("PASS \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
            else { fail += 1; print("FAIL \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
        }

        var base = AppSettings()
        base.searchApiKey = "test-key"
        base.searchMaxResults = 5

        // 未配置：应给出可读提示而不是请求
        var none = base; none.searchProvider = "none"
        check("未配置服务商抛出 notConfigured", (try? SearchClient.makeRequest(query: "x", settings: none)) == nil)

        // Tavily：POST + JSON 体
        var tavily = base; tavily.searchProvider = "tavily"
        if let r = try? SearchClient.makeRequest(query: "Swift 并发", settings: tavily) {
            check("Tavily 方法为 POST", r.httpMethod == "POST", r.httpMethod ?? "-")
            check("Tavily 地址", r.url?.absoluteString == "https://api.tavily.com/search", r.url?.absoluteString ?? "-")
            let body = String(data: r.httpBody ?? Data(), encoding: .utf8) ?? ""
            check("Tavily 体含 query", body.contains("Swift"), body.prefix(60).description)
            check("Tavily 体含 max_results", body.contains("max_results"))
        } else { check("Tavily 请求可构造", false) }

        // Brave：GET + 订阅头
        var brave = base; brave.searchProvider = "brave"
        if let r = try? SearchClient.makeRequest(query: "swift", settings: brave) {
            check("Brave 方法为 GET", r.httpMethod == "GET", r.httpMethod ?? "-")
            check("Brave 带订阅头", (r.value(forHTTPHeaderField: "X-Subscription-Token") ?? "") == "test-key")
            check("Brave 地址含 q", (r.url?.absoluteString ?? "").contains("q=swift"), r.url?.absoluteString ?? "-")
        } else { check("Brave 请求可构造", false) }

        // Serper：POST + X-API-KEY
        var serper = base; serper.searchProvider = "serper"
        if let r = try? SearchClient.makeRequest(query: "swift", settings: serper) {
            check("Serper 方法为 POST", r.httpMethod == "POST", r.httpMethod ?? "-")
            check("Serper 带 X-API-KEY", (r.value(forHTTPHeaderField: "X-API-KEY") ?? "") == "test-key")
        } else { check("Serper 请求可构造", false) }

        // 自定义：{query} 占位符 → GET
        var custom = base
        custom.searchProvider = "custom"
        custom.searchBaseURL = "https://example.com/s?q={query}"
        if let r = try? SearchClient.makeRequest(query: "hello world", settings: custom) {
            check("自定义含 {query} 时为 GET", r.httpMethod == "GET", r.httpMethod ?? "-")
            check("自定义已拼接关键词", (r.url?.absoluteString ?? "").contains("hello"), r.url?.absoluteString ?? "-")
        } else { check("自定义请求可构造", false) }

        // 响应解析：三家各自的 JSON 形状
        let tavilyJSON = #"{"answer":"综合答案","results":[{"title":"T1","url":"https://a","content":"C1"}]}"#
        if let resp = try? SearchClient.parse(Data(tavilyJSON.utf8), provider: .tavily) {
            check("解析 Tavily 结果", resp.results.count == 1 && resp.results[0].title == "T1")
            check("解析 Tavily 答案", resp.answer == "综合答案")
        } else { check("解析 Tavily 结果", false) }

        let braveJSON = #"{"web":{"results":[{"title":"B1","url":"https://b","description":"D1"}]}}"#
        if let resp = try? SearchClient.parse(Data(braveJSON.utf8), provider: .brave) {
            check("解析 Brave 结果", resp.results.count == 1 && resp.results[0].url == "https://b")
        } else { check("解析 Brave 结果", false) }

        let serperJSON = #"{"organic":[{"title":"S1","link":"https://c","snippet":"N1"}]}"#
        if let resp = try? SearchClient.parse(Data(serperJSON.utf8), provider: .serper) {
            check("解析 Serper 结果", resp.results.count == 1 && resp.results[0].snippet == "N1")
        } else { check("解析 Serper 结果", false) }

        // 容错：非 JSON 与空对象不应崩溃
        check("非 JSON 容错", (try? SearchClient.parse(Data("not json".utf8), provider: .tavily)) == nil
              || ((try? SearchClient.parse(Data("not json".utf8), provider: .tavily))?.results.isEmpty ?? true))
        _ = try? SearchClient.parse(Data("{}".utf8), provider: .tavily)

        // 错误映射
        check("401 提示 Key 无效", SearchError.http(401, "").message.contains("API Key"))
        check("429 提示限流", SearchError.http(429, "").message.contains("限流"))
        check("500 提示服务商不可用", SearchError.http(500, "").message.contains("服务商"))
        check("超时提示", SearchError.network("timed out").message.contains("网络"))

        // HTML → 纯文本
        let html = "<html><head><style>b{}</style></head><body><h1>标题</h1><script>x()</script><p>正文 &amp; 更多</p></body></html>"
        let plain = SearchClient.plainText(fromHTML: html)
        check("HTML 去标签", !plain.contains("<") && plain.contains("标题") && plain.contains("正文"))
        check("HTML 去脚本样式", !plain.contains("x()") && !plain.contains("b{}"))
        check("实体解码", plain.contains("&") && !plain.contains("&amp;"))

        print("结果: \(fail == 0 ? "全部通过" : "有 \(fail) 项失败")（搜索自检，通过 \(pass)/\(pass+fail)）")
    }

    /// 断言代理字典构造。
    static func proxyCheck() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1; print("PASS \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
            else { fail += 1; print("FAIL \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
        }

        var s = AppSettings()
        check("默认关闭时代理字典为空", NetworkProxy.proxyDictionary(s).isEmpty)
        check("默认关闭时不启用", !NetworkProxy.isActive(s))

        s.proxyEnabled = true
        s.proxyType = "http"
        s.proxyHost = "127.0.0.1"
        s.proxyPort = 7890
        var d = NetworkProxy.proxyDictionary(s)
        check("HTTP 启用键", (d["HTTPEnable"] as? Int) == 1)
        check("HTTP 主机", (d["HTTPProxy"] as? String) == "127.0.0.1")
        check("HTTP 端口", (d["HTTPPort"] as? Int) == 7890)

        s.proxyType = "https"
        d = NetworkProxy.proxyDictionary(s)
        check("HTTPS 启用键", (d["HTTPSEnable"] as? Int) == 1)
        check("HTTPS 主机", (d["HTTPSProxy"] as? String) == "127.0.0.1")

        s.proxyType = "socks5"
        d = NetworkProxy.proxyDictionary(s)
        check("SOCKS 启用键", (d["SOCKSEnable"] as? Int) == 1)
        check("SOCKS 主机", (d["SOCKSProxy"] as? String) == "127.0.0.1")

        s.proxyType = "http"
        s.proxyUsername = "u"
        s.proxyPassword = "p"
        d = NetworkProxy.proxyDictionary(s)
        check("含认证", (d["HTTPProxyUsername"] as? String) == "u" && (d["HTTPProxyPassword"] as? String) == "p")

        s.proxyUsername = ""
        s.proxyPassword = ""
        s.proxyBypass = "localhost, *.local"
        d = NetworkProxy.proxyDictionary(s)
        check("绕过列表", (d["ExceptionsList"] as? [String])?.contains("localhost") == true
              && (d["ExceptionsList"] as? [String])?.contains("*.local") == true)

        s.proxyHost = ""
        check("主机为空时不启用", NetworkProxy.proxyDictionary(s).isEmpty)
        s.proxyHost = "127.0.0.1"
        s.proxyPort = 0
        check("端口为 0 时不启用", NetworkProxy.proxyDictionary(s).isEmpty)

        // 会话配置可构造
        s.proxyPort = 7890
        let cfg = NetworkProxy.sessionConfiguration(s)
        check("会话配置带代理", !(cfg.connectionProxyDictionary ?? [:]).isEmpty)

        print("结果: \(fail == 0 ? "全部通过" : "有 \(fail) 项失败")（代理自检，通过 \(pass)/\(pass+fail)）")
    }

    static func markdownCheck() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        let base: CGFloat = 14
        let fixture = """
        # 一级标题

        ## 二级标题

        ### 三级标题

        这是**粗体**、*斜体*、`行内代码` 与 ~~删除线~~，以及 [Myna 官网](https://github.com/quyansiyuanwang/myna)。

        - 第一层项目
          - 第二层项目
        - 第一层第二项

        3. 从三开始
        4. 接着是四

        > 引用块示例

        ---

        | 列 A | 列 B | 列 C |
        | --- | --- | --- |
        | 值 1 | 值 2 | 值 3 |
        | 长一些的值 | x | y |

        ```swift
        let answer = 42
        ```
        """
        let blocks = MarkdownParser.parse(fixture)

        func headingText(_ level: Int) -> String? {
            for b in blocks { if case .heading(let l, let t) = b, l == level { return t } }
            return nil
        }
        func span(_ line: String, _ text: String) -> MarkdownSpan? {
            MarkdownInline.spans(line).first { $0.text == text }
        }
        func spec(_ span: MarkdownSpan, size: CGFloat = base, weight: Font.Weight = .regular) -> MarkdownInlineSpec {
            MarkdownInline.spec(for: span.styles, size: size, weight: weight)
        }

        // 标题：分级字号 + 字重
        for (level, expected) in [(1, "一级标题"), (2, "二级标题"), (3, "三级标题")] {
            let text = headingText(level)
            let size = MarkdownLayout.headingSize(level, base: base)
            let weight = MarkdownLayout.headingWeight(level)
            let expectedSize = level == 1 ? base + 7 : (level == 2 ? base + 4 : base + 2)
            let expectedWeight: Font.Weight = level == 1 ? .bold : .semibold
            check("h\(level)", text == expected && size == expectedSize && weight == expectedWeight,
                  "文本=\(text ?? "nil") 字号=\(size)（期望 \(expectedSize)）字重=\(weight == .bold ? "bold" : "semibold")")
        }

        // 内联样式
        let line = "这是**粗体**、*斜体*、`行内代码` 与 ~~删除线~~，以及 [Myna 官网](https://github.com/quyansiyuanwang/myna)。"
        if let bold = span(line, "粗体") {
            let s = spec(bold)
            check("粗体", bold.has(.strong) && s.weight == .bold && s.size == base && !s.italic,
                  "字号=\(s.size) 字重=bold")
        } else {
            check("粗体", false, "未解析出样式段")
        }
        if let italic = span(line, "斜体") {
            let s = spec(italic)
            check("斜体", italic.has(.emphasis) && s.italic && s.size == base,
                  "字号=\(s.size) 斜体=\(s.italic)")
        } else {
            check("斜体", false, "未解析出样式段")
        }
        if let code = span(line, "行内代码") {
            let s = spec(code)
            check("行内代码", code.has(.code) && s.monospaced && s.size == base - 1 && s.background && s.foreground == .accent,
                  "字号=\(s.size) 等宽=\(s.monospaced) 底色=\(s.background) 前景=accent")
        } else {
            check("行内代码", false, "未解析出样式段")
        }
        if let strike = span(line, "删除线") {
            let s = spec(strike)
            check("删除线", strike.has(.strikethrough) && s.strikethrough && s.foreground == .secondary,
                  "删除线=\(s.strikethrough) 前景=secondary")
        } else {
            check("删除线", false, "未解析出样式段")
        }
        if let link = span(line, "Myna 官网") {
            let s = spec(link)
            check("链接", link.has(.link) && s.underline && s.foreground == .accent,
                  "下划线=\(s.underline) 前景=accent")
        } else {
            check("链接", false, "未解析出样式段")
        }

        // 列表
        let bullets = blocks.compactMap { b -> (Int, String)? in
            if case .bullet(let depth, let text) = b { return (depth, text) }
            return nil
        }
        check("无序列表（两级）",
              bullets.contains { $0.0 == 0 && $0.1 == "第一层项目" } &&
              bullets.contains { $0.0 == 1 && $0.1 == "第二层项目" } &&
              MarkdownLayout.bulletMark(depth: 0) == "•" && MarkdownLayout.bulletMark(depth: 1) == "◦",
              bullets.map { "\($0.0):\($0.1)" }.joined(separator: " "))

        let ordered = blocks.compactMap { b -> (Int, Int, String)? in
            if case .ordered(let depth, let number, let text) = b { return (depth, number, text) }
            return nil
        }
        check("有序列表（从 3 开始）",
              ordered.count >= 2 && ordered[0].1 == 3 && ordered[1].1 == 4,
              ordered.map { "\($0.1).\($0.2)" }.joined(separator: " "))

        // 引用块：`>` 必须被剥离
        if let quote = blocks.compactMap({ b -> String? in
            if case .blockquote(let t) = b { return t }
            return nil
        }).first {
            check("引用块", quote == "引用块示例" && !quote.contains(">"), "内容=\(quote)")
        } else {
            check("引用块", false, "未解析出引用块")
        }
        check("引用块（嵌套 >>）", MarkdownParser.stripQuote(">> 嵌套引用") == "嵌套引用",
              "stripQuote(\">> 嵌套引用\")=\(MarkdownParser.stripQuote(">> 嵌套引用"))")

        // 分隔线
        check("分隔线", blocks.contains { if case .rule = $0 { return true } else { return false } },
              "“---” 识别为 rule")

        // 表格
        if let table = blocks.compactMap({ b -> MarkdownTable? in
            if case .table(let t) = b { return t }
            return nil
        }).first {
            let padded = table.paddedLines()
            let widths = Set(([padded.header] + padded.rows).map { MarkdownTable.displayWidth($0) })
            check("GFM 表格",
                  table.header == ["列 A", "列 B", "列 C"] && table.rows.count == 2 &&
                  table.rows[0] == ["值 1", "值 2", "值 3"] && widths.count == 1,
                  "表头=\(table.header) 行数=\(table.rows.count) 对齐宽度=\(widths.sorted())")
        } else {
            check("GFM 表格", false, "未解析出表格")
        }

        // 代码块
        let codes = blocks.compactMap { b -> (String, String?)? in
            if case .code(let code, let language) = b { return (code, language) }
            return nil
        }
        check("围栏代码块（含语言）",
              codes.contains { $0.0 == "let answer = 42" && $0.1 == "swift" },
              codes.map { "lang=\($0.1 ?? "nil")" }.joined(separator: " "))

        // 流式：未闭合围栏 / 半截表格 / 单独的 `|`
        let partialFence = MarkdownParser.parse("```swift\nlet x = 1")
        let partialCode = partialFence.compactMap { b -> (String, String?)? in
            if case .code(let code, let language) = b { return (code, language) }
            return nil
        }
        check("未闭合围栏",
              partialCode.contains { $0.0 == "let x = 1" && $0.1 == "swift" },
              partialCode.map { "lang=\($0.1 ?? "nil") code=\($0.0)" }.joined(separator: " "))
        let emptyFence = MarkdownParser.parse("```")
        check("空围栏不丢文本", emptyFence.contains { if case .code("", nil) = $0 { return true } else { return false } },
              "``` → 空代码块")
        let halfTable = MarkdownParser.parse("| 列 A | 列 B |\n| --- | --- |\n| 值 1")
        check("半截表格", halfTable.contains { if case .table(let t) = $0 { return t.header.count == 2 } else { return false } },
              "表头 2 列，行可缺列")
        let lonePipe = MarkdownParser.parse("|")
        check("单独 | 退回段落", lonePipe.count == 1 && { if case .paragraph = lonePipe[0] { return true } else { return false } }(),
              "不误判为表格")

        // 流式：逐字符前缀都要能解析出块，不得崩溃
        var prefixOK = true
        var prefixCount = 0
        for end in 0...fixture.count {
            let parsed = MarkdownParser.parse(String(fixture.prefix(end)))
            prefixCount += 1
            if parsed.isEmpty { prefixOK = false; break }
        }
        check("流式：全前缀解析稳定", prefixOK, "\(prefixCount) 个前缀均返回至少一个块")
        let midFence = MarkdownParser.parse("正文\n```swift\nlet x =")
        check("流式：围栏中间不丢代码",
              midFence.contains { if case .code("let x =", "swift") = $0 { return true } else { return false } },
              "半截围栏正文完整保留")

        // 显式属性：不依赖 Text 解释 inline intent
        let boldAttr = MarkdownInline.attributed("**加粗**", size: base, accent: .blue)
        check("显式属性：粗体 font", boldAttr.runs.first?.font != nil, "run.font 已写入")
        let codeAttr = MarkdownInline.attributed("`x`", size: base, accent: .blue)
        let codeRun = codeAttr.runs.first
        check("显式属性：行内代码",
              codeRun?.font != nil && codeRun?.foregroundColor != nil && codeRun?.backgroundColor != nil,
              "font / foregroundColor / backgroundColor 均写入")
        let strikeAttr = MarkdownInline.attributed("~~x~~", size: base, accent: .blue)
        check("显式属性：删除线", strikeAttr.runs.first?.strikethroughStyle != nil, "strikethroughStyle 已写入")
        let linkAttr = MarkdownInline.attributed("[x](https://example.com)", size: base, accent: .blue)
        let linkRun = linkAttr.runs.first
        check("显式属性：链接",
              linkRun?.underlineStyle != nil && linkRun?.foregroundColor != nil,
              "underlineStyle / foregroundColor 已写入")
        let plainAttr = MarkdownInline.attributed("普通文本", size: base, accent: .blue)
        check("显式属性：正文不覆盖外层前景",
              plainAttr.runs.first?.foregroundColor == nil,
              "foregroundColor 留空以继承气泡颜色")

        print(failures == 0 ? "结果: 全部通过（Markdown 渲染自检）" : "结果: \(failures) 项失败")
        if failures > 0 { exit(1) }
    }

    // MARK: - 更新检查自检

    /// 隐藏命令 `myna update-check`：打印当前版本、最新版本（或错误）与比较结果，
    /// 并跑一组纯版本比较断言与错误映射断言，最后做一次实时检查。
    static func updateCheck() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        let current = UpdateChecker.currentVersion
        print("当前版本: \(current)")

        // 纯函数：语义化版本比较（忽略前缀 v、缺段补 0、预发布小于正式版）
        let cases: [(String, String, ComparisonResult, Bool)] = [
            ("1.10.0", "1.9.0", .orderedDescending, true),
            ("v0.12.2", "0.12.2", .orderedSame, false),
            ("1.0", "1.0.0", .orderedSame, false),
            ("2.0.0-beta", "1.9.9", .orderedDescending, true),
            ("1.0.0", "1.0.0-beta", .orderedDescending, true),
            ("1.0.0-beta", "1.0.0", .orderedAscending, false),
            ("0.9.2", "1.0.0", .orderedAscending, false),
            ("1.2", "1.2.1", .orderedAscending, false),
            ("2", "2.0.0", .orderedSame, false),
            ("V1.2.3", "1.2.3", .orderedSame, false),
        ]
        for (a, b, expected, newer) in cases {
            let got = UpdateChecker.compareVersions(a, b)
            let relation = got == .orderedDescending ? ">" : (got == .orderedAscending ? "<" : "==")
            check("比较 \(a) vs \(b)",
                  got == expected && UpdateChecker.isNewer(a, than: b) == newer,
                  "\(a) \(relation) \(b)")
        }

        // 错误映射：离线 / 限流 / 未找到
        check("限流 403", UpdateChecker.message(forHTTPStatus: 403).contains("限流"),
              UpdateChecker.message(forHTTPStatus: 403))
        check("限流 429", UpdateChecker.message(forHTTPStatus: 429).contains("限流"),
              UpdateChecker.message(forHTTPStatus: 429))
        check("未找到 404", UpdateChecker.message(forHTTPStatus: 404).contains("未找到"),
              UpdateChecker.message(forHTTPStatus: 404))
        check("离线", UpdateChecker.message(for: URLError(.notConnectedToInternet)).contains("网络"),
              UpdateChecker.message(for: URLError(.notConnectedToInternet)))
        check("超时", UpdateChecker.message(for: URLError(.timedOut)).contains("超时"),
              UpdateChecker.message(for: URLError(.timedOut)))

        // 解析：真实响应形状 / 非 JSON / 缺字段
        let fixture = #"{"tag_name":"v99.0.0","html_url":"https://github.com/quyansiyuanwang/myna/releases/tag/v99.0.0","name":"99.0.0","body":"更新说明","published_at":"2099-01-02T03:04:05Z","assets":[{"name":"Myna-v99.0.0.zip"}]}"#
        if let data = fixture.data(using: .utf8) {
            let parsed = UpdateChecker.parse(data: data, current: current)
            check("解析：可用更新", parsed.availableVersion == "99.0.0", parsed.summary)
        }
        check("解析：非 JSON", UpdateChecker.parse(data: Data("not json".utf8), current: current).availableVersion == nil,
              "容错为 failed")
        check("解析：缺 tag", UpdateChecker.parse(data: Data("{}".utf8), current: current).availableVersion == nil,
              "容错为 failed")

        // 实时检查（离线时给出可读失败）
        let checker = UpdateChecker()
        print("请求地址: \(checker.endpoint.absoluteString)")
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task {
            box.value = describeUpdate(await checker.check())
            sem.signal()
        }
        if sem.wait(timeout: .now() + 20) == .timedOut {
            print("检查结果: 超时（20s）")
            failures += 1
        } else {
            print("检查结果: \(box.value)")
        }

        print(failures == 0 ? "结果: 全部通过（更新检查自检）" : "结果: \(failures) 项失败")
        if failures > 0 { exit(1) }
    }

    private static func describeUpdate(_ result: UpdateCheckResult) -> String {
        switch result {
        case .upToDate(let current):
            return "已是最新版本（当前 \(current)）"
        case .updateAvailable(let current, let latest, let url, _, let publishedAt):
            let date = publishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "未知时间"
            return "发现新版本 \(latest)（当前 \(current)，发布 \(date)，\(url?.absoluteString ?? "无链接")）"
        case .failed(let message):
            return "检查失败：\(message)"
        }
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

    // MARK: - 会话工作目录持久化自检

    /// 隐藏命令 `myna conversation-dir set <dir>` / `get <id>` / `clear <id>`。
    static func conversationDirCommand(_ args: [String]) {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = runConversationDir(args)
            done.signal()
        }
        let deadline = Date().addingTimeInterval(30)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() > deadline { box.value = "超时"; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        print(box.value)
    }

    @MainActor
    private static func runConversationDir(_ args: [String]) -> String {
        let store = ConversationStore.shared
        let model = ChatModel()
        guard let sub = args.first else {
            return "用法: myna conversation-dir set <dir> | get <id> | clear <id>"
        }
        switch sub {
        case "set":
            let dir = args.count > 1 ? args[1] : ""
            model.newConversation()
            guard let id = store.currentID else { return "创建会话失败" }
            model.setWorkingDirectory(dir, for: id)
            store.flush()
            return "\(id.uuidString)\t\(dir)"
        case "get":
            guard args.count > 1, let id = UUID(uuidString: args[1]),
                  let c = store.conversations.first(where: { $0.id == id }) else {
                return "未找到会话"
            }
            return "\(id.uuidString)\t\(c.workingDirectory)\t解析=\(model.workingDirectory(for: id))"
        case "clear":
            guard args.count > 1, let id = UUID(uuidString: args[1]) else { return "缺少会话 id" }
            model.deleteConversation(id)
            store.flush()
            return "已删除 \(id.uuidString)"
        default:
            return "未知子命令：\(sub)"
        }
    }

    // MARK: - 工作目录自检

    /// 隐藏命令 `myna working-dir-check`：验证工作目录属于会话而非全局。
    static func workingDirCheck() {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await runWorkingDirCheck()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(120)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() > deadline {
                box.value = "FAIL\n  [!!] 超时（120s）"
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        print(box.value)
        if !box.value.hasPrefix("PASS") { exit(1) }
    }

    /// 并发收集结果的小盒子。
    private final class LockedList: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Int, String)] = []
        func append(_ index: Int, _ value: String) {
            lock.lock(); items.append((index, value)); lock.unlock()
        }
        var sorted: [String] {
            lock.lock(); defer { lock.unlock() }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    @MainActor
    private static func runWorkingDirCheck() async -> String {
        let settingsStore = SettingsStore.shared
        let store = ConversationStore.shared
        let model = ChatModel()
        let fm = FileManager.default
        var lines: [String] = []
        var ok = true
        func check(_ cond: Bool, _ msg: String) {
            lines.append((cond ? "  [ok] " : "  [!!] ") + msg)
            if !cond { ok = false }
        }

        let originalGlobal = settingsStore.settings.workingDirectory
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("myna-wd-\(UUID().uuidString)")
        let dirA = (root as NSString).appendingPathComponent("alpha")
        let dirB = (root as NSString).appendingPathComponent("beta")
        let dirC = (root as NSString).appendingPathComponent("gamma")
        let globalDir = (root as NSString).appendingPathComponent("global")
        for d in [dirA, dirB, dirC, globalDir] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try? "alpha".write(toFile: (dirA as NSString).appendingPathComponent("a-only.txt"), atomically: true, encoding: .utf8)
        try? "beta".write(toFile: (dirB as NSString).appendingPathComponent("b-only.txt"), atomically: true, encoding: .utf8)

        // 应用默认 = globalDir，用于验证回退。
        settingsStore.settings.workingDirectory = globalDir

        model.newConversation(); guard let idA = store.currentID else { return "FAIL\n  [!!] 创建会话 A 失败" }
        model.newConversation(); guard let idB = store.currentID else { return "FAIL\n  [!!] 创建会话 B 失败" }
        model.newConversation(); guard let idC = store.currentID else { return "FAIL\n  [!!] 创建会话 C 失败" }
        model.newConversation(); guard let idD = store.currentID else { return "FAIL\n  [!!] 创建会话 D 失败" }

        model.setWorkingDirectory(dirA, for: idA)
        model.setWorkingDirectory(dirB, for: idB)

        // 1) 解析：会话自设 > 应用默认 > 用户主目录
        let resolvedA = model.workingDirectory(for: idA)
        let resolvedB = model.workingDirectory(for: idB)
        let resolvedC = model.workingDirectory(for: idC)
        lines.append("A 目录: \(resolvedA)")
        lines.append("B 目录: \(resolvedB)")
        lines.append("C 目录（无自设，应用默认=\(globalDir)）: \(resolvedC)")
        check(resolvedA == dirA, "会话 A 使用自己的目录")
        check(resolvedB == dirB, "会话 B 使用自己的目录")
        check(resolvedC == globalDir, "会话 C 回退到应用默认")

        settingsStore.settings.workingDirectory = ""
        let resolvedD = model.workingDirectory(for: idD)
        let home = NSString(string: "~").expandingTildeInPath
        lines.append("D 目录（无自设，应用默认为空）: \(resolvedD)")
        check(resolvedD == home, "应用默认为空时回退到用户主目录")
        settingsStore.settings.workingDirectory = globalDir

        // 2) 工具路径：相对路径按各自会话目录解析（写 / 读）
        let writeA = ToolRunner.run(name: "write_file",
                                    args: ["path": "marker.txt", "content": "A-content"],
                                    workingDirectory: resolvedA)
        let writeB = ToolRunner.run(name: "write_file",
                                    args: ["path": "marker.txt", "content": "B-content"],
                                    workingDirectory: resolvedB)
        lines.append("写 A: \(writeA)")
        lines.append("写 B: \(writeB)")
        check(fm.fileExists(atPath: (dirA as NSString).appendingPathComponent("marker.txt")), "A 的相对路径写入 A 目录")
        check(fm.fileExists(atPath: (dirB as NSString).appendingPathComponent("marker.txt")), "B 的相对路径写入 B 目录")

        // 3) 并发：两个会话同时跑 list_dir / read_file，互不串目录
        let box = LockedList()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let dir = i == 0 ? resolvedA : resolvedB
            let list = ToolRunner.run(name: "list_dir", args: [:], workingDirectory: dir)
            let read = ToolRunner.run(name: "read_file", args: ["path": "marker.txt"], workingDirectory: dir)
            box.append(i, list + "\n--\n" + read)
        }
        let concurrent = box.sorted
        let outA = concurrent.first ?? ""
        let outB = concurrent.count > 1 ? concurrent[1] : ""
        lines.append("并发 A:\n\(outA)")
        lines.append("并发 B:\n\(outB)")
        check(outA.contains(dirA) && !outA.contains(dirB) && outA.contains("a-only.txt") && outA.contains("A-content"),
              "并发时 A 的工具在 A 目录解析")
        check(outB.contains(dirB) && !outB.contains(dirA) && outB.contains("b-only.txt") && outB.contains("B-content"),
              "并发时 B 的工具在 B 目录解析")

        // 4) 导出 / 导入：working_directory 往返
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var importedID: UUID?
        if let cA = store.conversations.first(where: { $0.id == idA }), let data = try? enc.encode(cA) {
            if let round = try? dec.decode(Conversation.self, from: data) {
                check(round.workingDirectory == dirA, "导出 / 导入 JSON 保留工作目录")
                let inserted = store.insert(round)
                importedID = inserted.id
                check(inserted.workingDirectory == dirA, "导入后新会话仍指向原工作目录")
            } else {
                check(false, "导入解码失败")
            }
        } else {
            check(false, "导出编码失败")
        }

        // 旧文件缺 working_directory 时默认空（回退应用默认）。
        let legacy = Data(#"{"id":"4E9B0A9B-0000-0000-0000-000000000000","title":"旧会话","bubbles":[]}"#.utf8)
        if let old = try? dec.decode(Conversation.self, from: legacy) {
            check(old.workingDirectory == "", "旧会话文件缺少字段时默认为空")
        } else {
            check(false, "旧会话文件解码失败")
        }

        // 5) 签名重建：改 A 的目录只重建 A 的 Agent
        await model.ensureAgentForCheck(for: idA)
        await model.ensureAgentForCheck(for: idB)
        let sigA1 = model.agentSignature(for: idA) ?? ""
        let sigB1 = model.agentSignature(for: idB) ?? ""
        let agentA1 = model.agentIdentity(for: idA)
        let agentB1 = model.agentIdentity(for: idB)
        lines.append("签名 A1=\(sigA1.suffix(24)) B1=\(sigB1.suffix(24))")
        model.setWorkingDirectory(dirC, for: idA)
        await model.ensureAgentForCheck(for: idA)
        await model.ensureAgentForCheck(for: idB)
        let sigA2 = model.agentSignature(for: idA) ?? ""
        let sigB2 = model.agentSignature(for: idB) ?? ""
        let agentA2 = model.agentIdentity(for: idA)
        let agentB2 = model.agentIdentity(for: idB)
        lines.append("签名 A2=\(sigA2.suffix(24)) B2=\(sigB2.suffix(24))")
        check(sigA1 != sigA2, "改 A 的目录后 A 的签名变化")
        check(agentA1 != nil && agentA2 != nil && agentA1 != agentA2, "A 的 Agent 已重建")
        check(sigB1 == sigB2, "B 的签名不因 A 改变而变化")
        check(agentB1 == agentB2, "B 的 Agent 未被重建")

        // 清理：删除测试会话，恢复应用默认并落盘。
        for id in [idA, idB, idC, idD] + [importedID].compactMap({ $0 }) {
            model.deleteConversation(id)
        }
        settingsStore.settings.workingDirectory = originalGlobal
        settingsStore.flush()
        store.flush()
        try? fm.removeItem(atPath: root)
        return ([ok ? "PASS" : "FAIL"] + lines).joined(separator: "\n")
    }
}
