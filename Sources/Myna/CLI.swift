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
        case "market-install":
            // 隐藏命令：从社区仓库安装技能 / MCP / 插件（用于验证与脚本化安装）。
            marketInstall(Array(args.dropFirst()))
        case "agent":
            runPackageAgent(args.dropFirst().joined(separator: " "))
        case "help", "--help", "-h":
            print("""
            Myna 命令行
              Myna ask "问题"          调用大模型并执行本机操作，结果打印到 stdout
              echo "问题" | Myna ask   从标准输入读取问题
              Myna tool <name> [json]  直接执行某个本机工具
              Myna tools               列出全部工具
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
}
