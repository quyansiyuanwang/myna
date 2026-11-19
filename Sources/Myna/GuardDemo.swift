import Foundation
import Combine
import PiKit

enum GuardDemo {
    static let filename = "演示草稿.txt"
    static let toolName = "delete_path"

    struct Receipt {
        let block: GuardActivity.Block
        fileprivate init(_ block: GuardActivity.Block) { self.block = block }

        var summary: String {
            """
            Myna 本地拦截演示 · 验证通过
            验证时间：\(block.date.formatted(.iso8601))
            模拟请求：\(block.tool)（临时样本：\(GuardDemo.filename)）
            拦截原因：\(block.reason.rawValue)
            文件核验：已读回样本，内容与请求前一致。
            本次为本地演示，未调用模型，不计入真实拦截次数。
            """
        }
    }

    /// 与页面生命周期分离：查看能力清单或返回聊天时仍然保留本次验证。
    @MainActor final class Session: ObservableObject {
        static let shared = Session()
        enum State { case idle, running, verified(Receipt), failed(String) }
        @Published private(set) var state = State.idle

        var isRunning: Bool {
            if case .running = state { return true }
            return false
        }

        func verify() async {
            if case .running = state { return }
            state = .running
            do { state = .verified(try await GuardDemo.run()) }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    enum Failure: LocalizedError {
        case missingTool, notVerified
        var errorDescription: String? {
            switch self {
            case .missingTool: return "未找到删除工具。"
            case .notVerified: return "未能同时验证拒绝记录与文件内容，请勿将本次结果作为拦截证据。"
            }
        }
    }

    /// 真实的执行入口、隔离的审计计数和一次性样本。演示不发模型请求。
    private static func run() async throws -> Receipt {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("myna-guard-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent(filename)
        let original = Data(UUID().uuidString.utf8)
        try original.write(to: file)
        let center = await ToolPermissionCenter()
        guard let tool = ToolRunner.packageTools(only: [toolName], workingDirectory: dir.path,
                                                 mode: .plan, permissionCenter: center).first else { throw Failure.missingTool }
        let call = ToolCall(id: UUID().uuidString, name: tool.name, arguments: .object(["path": .string(filename)]))
        let result = try await tool.execute(call, onUpdate: nil)
        guard result.isError, let block = await center.activity.latest, block.reason == .plan,
              try Data(contentsOf: file) == original else { throw Failure.notVerified }
        return Receipt(block)
    }
}
