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

    /// 现场快照的数据来源，由 AppDelegate 在启动时注入。
    nonisolated(unsafe) static var snapshot: () -> String = { "" }

    static var logPath: String {
        NSString(string: "~/.config/myna/stall.log").expandingTildeInPath
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
        // 5 秒内主线程仍未回应，先记一笔（此时 `answered` 必然为 false）
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if !answered, Date().timeIntervalSince(lastRecord) > recordInterval {
                lastRecord = Date()
                record(latency: 5, answeredHere: false)
            }
        }
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
