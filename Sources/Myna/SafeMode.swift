import Foundation

/// 安全模式。
///
/// 主线程一旦卡在一次无限的布局里，进程内没有任何办法把栈解开——用户只能强杀。
/// 看门狗（``StallWatchdog``）因此负起「恢复」的责任：确认卡死之后写一个标记文件、
/// 重启进程，下次启动就进入安全模式。
///
/// 安全模式只改**界面渲染方式**（关掉滚动观测、导航轨、悬停操作条，并把渲染条数压到很小），
/// 不改用户的配置：卡死不能顺带把设置改坏。
enum SafeMode {
    struct State: Codable {
        var reason: String
        var since: Date
        var relaunchCount: Int
        /// 上一次自动重启的时刻，用于限流（老版本文件没有这个字段，解码失败时按 nil 处理）。
        var lastRelaunch: Date?
    }

    static var path: String {
        NSString(string: "~/.config/myna/safe-mode.json").expandingTildeInPath
    }

    /// 本次启动是否处于安全模式。
    nonisolated(unsafe) static private(set) var isOn = false
    nonisolated(unsafe) static private(set) var state: State?

    /// 安全模式下的渲染条数上限。
    static let renderCap = 60

    static func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(State.self, from: data) else {
            isOn = false
            state = nil
            return
        }
        isOn = true
        state = s
    }

    /// 记录一次卡死，并返回是否应该重启进程。
    ///
    /// 限流：10 分钟内最多自动重启一次，避免「安全模式下也卡住 → 无限重启」。
    static func recordStall(reason: String) -> Bool {
        var s = state ?? State(reason: reason, since: Date(), relaunchCount: 0, lastRelaunch: nil)
        // 首次卡死就应该重启；只有「10 分钟内已经重启过」才不重启，避免重启风暴。
        let now = Date()
        let shouldRelaunch = s.lastRelaunch.map { now.timeIntervalSince($0) > 600 } ?? true
        if shouldRelaunch {
            s.relaunchCount += 1
            s.lastRelaunch = now
        }
        s.reason = reason
        state = s
        isOn = true
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
        return shouldRelaunch
    }

    /// 用户主动退出安全模式。
    static func disable() {
        try? FileManager.default.removeItem(atPath: path)
        isOn = false
        state = nil
    }

    static var summary: String {
        guard let s = state else { return "安全模式已开启" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return "安全模式：\(fmt.string(from: s.since)) 因界面卡死自动进入"
    }
}
