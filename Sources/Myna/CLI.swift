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
        case "market-install":
            // 隐藏命令：从社区仓库安装技能 / MCP / 插件（用于验证与脚本化安装）。
            marketInstall(Array(args.dropFirst()))
        case "agent":
            runPackageAgent(args.dropFirst().joined(separator: " "))
        case "concurrency-check":
            // 隐藏命令：用真实 ChatModel 验证多会话并行运行互不干扰（供 CI / 本地验证）。
            concurrencyCheck()
        case "help", "--help", "-h":
            print("""
            Myna 命令行
              Myna ask "问题"          调用大模型并执行本机操作，结果打印到 stdout
              echo "问题" | Myna ask   从标准输入读取问题
              Myna tool <name> [json]  直接执行某个本机工具
              Myna tools               列出全部工具
              Myna models              按当前配置探测可用模型并打印 id
              Myna agent "问题"        用 Swift 包 Agent 运行时对话（PiAI + PiAgentCore）
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
    static func listModels() {
        let settings = SettingsStore.shared.settings
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
                for id in ids { print(id) }
            } catch {
                FileHandle.standardError.write(Data("错误: \(error.localizedDescription)\n".utf8))
            }
            sem.signal()
        }
        sem.wait()
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
}
