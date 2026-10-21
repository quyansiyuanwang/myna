import Foundation

/// 主线程卡死看门狗。
///
/// 界面卡死时用户只能强杀，事后什么线索都没有。这里从后台线程每秒向主队列投一次
/// 探针：正常情况延迟在毫秒级；一旦主线程被拖住（布局循环、超长重排），延迟会随
/// 卡顿时长增长。超过阈值就写一份现场快照到 `~/.config/myna/stall.log`：
/// 卡顿时长、会话规模、是否在运行、窗口尺寸，以及 `ChatView.body` 的求值速率
/// —— 求值速率不正常地高，就说明是 SwiftUI 更新循环而不是单纯的渲染慢。
enum StallWatchdog {
    static let threshold: TimeInterval = 2.5
    /// 两次记录之间的最小间隔，避免卡死期间日志被刷爆。
    private static let recordInterval: TimeInterval = 30

    nonisolated(unsafe) private static var lastRecord = Date.distantPast
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var lastRecoveryAttempt = Date.distantPast

    /// 现场快照的数据来源，由 AppDelegate 在启动时注入。
    nonisolated(unsafe) static var snapshot: () -> String = { "" }

    /// 判定「真卡死」的时长：主线程连续这么久不回应就不再指望它自己恢复。
    static let recoveryThreshold: TimeInterval = 8

    static var logPath: String {
        if let custom = ProcessInfo.processInfo.environment["MYNA_STALL_LOG"] { return custom }
        let configPath = SettingsStore.shared.path
        let dir = (configPath as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("stall.log")
    }

    static func start() {
        guard !started else { return }
        started = true
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 10, repeating: 1)
        t.setEventHandler { ping() }
        t.resume()
        timer = t
    }

    private static func ping() {
        let begin = Date()
        var answered = false
        DispatchQueue.main.async {
            answered = true
            let latency = Date().timeIntervalSince(begin)
            if latency > threshold, Date().timeIntervalSince(lastRecord) > recordInterval {
                lastRecord = Date()
                record(latency: latency, answeredHere: true)
            }
        }
        // 8 秒仍未回应：主线程卡在一次布局里出不来了。
        // 记一笔现场，然后带安全模式重启——进程内无法解开卡住的栈，但可以让用户回到可用状态。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + recoveryThreshold) {
            guard !answered else { return }
            // 每秒一次的探针会各排一次这个 block，这里必须只处理一次。
            guard Date().timeIntervalSince(lastRecoveryAttempt) > 10 else { return }
            lastRecoveryAttempt = Date()
            record(latency: recoveryThreshold, answeredHere: false)
            recover()
        }
    }

    /// 带安全模式重启：先落标记文件，再让一个独立进程在当前进程退出后拉起 App。
    private static func recover() {
        let reason = "主线程连续 \(Int(Self.recoveryThreshold))s 无响应"
        guard SafeMode.recordStall(reason: reason) else { return }
        let app = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -a \(shellQuote(app))"]
        try? task.run()
        appendLogLine("检测到主线程卡死，带安全模式重启")
        exit(1)
    }

    /// 往 stall.log 追一行纯文本。
    private static func appendLogLine(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func record(latency: TimeInterval, answeredHere: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = snapshot()
        let line = """
        [\(stamp)] 主线程阻塞 ≥\(String(format: "%.1f", latency))s \
        (\(answeredHere ? "已被探针确认" : "探针 5s 未回应"))
        \(body)

        """
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
