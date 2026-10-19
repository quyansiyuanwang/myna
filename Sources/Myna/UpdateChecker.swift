import Foundation
import Combine

/// 更新检查结果。
///
/// 纯值类型，便于在设置界面、CLI 与自动检查三条路径之间传递。
enum UpdateCheckResult: Equatable, Sendable {
    /// 已是最新版本。
    case upToDate(current: String)
    /// 发现新版本。`url` 为发布页地址，`notes` 为发布说明，`publishedAt` 为发布时间。
    case updateAvailable(current: String, latest: String, url: URL?, notes: String, publishedAt: Date?)
    /// 检查失败，`message` 为可直接展示给用户的中文原因。
    case failed(message: String)
}

/// GitHub Releases 更新检查器。
///
/// 零第三方依赖：只读取应用包内的 `CFBundleShortVersionString`，用
/// `URLSession` 请求 GitHub Releases API，再按语义化版本比较。
/// 版本比较是纯静态函数，可脱离网络单独测试（见 `myna update-check`）。
struct UpdateChecker: Sendable {
    /// 官方发布查询地址。
    static let releasesURL = URL(string: "https://api.github.com/repos/quyansiyuanwang/myna/releases/latest")!
    /// 网络超时（秒）。单次请求不宜久等，失败即回退到「检查失败」。
    static let defaultTimeout: TimeInterval = 10

    /// 实际请求地址；可用 `MYNA_UPDATE_ENDPOINT` 覆盖（便于离线 / 镜像测试）。
    var endpoint: URL = UpdateChecker.defaultEndpoint
    /// 请求超时。
    var timeout: TimeInterval = UpdateChecker.defaultTimeout
    /// GitHub 要求请求必须带 User-Agent。
    var userAgent: String = "Myna"

    /// 默认查询地址，支持 `MYNA_UPDATE_ENDPOINT` 环境变量覆盖。
    static var defaultEndpoint: URL {
        if let raw = ProcessInfo.processInfo.environment["MYNA_UPDATE_ENDPOINT"],
           !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return releasesURL
    }

    /// 当前应用版本：读取包内 `CFBundleShortVersionString`，缺失时回退 `0.0.0`。
    static var currentVersion: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "0.0.0"
    }

    // MARK: - 网络检查

    /// 请求 GitHub Releases 并返回检查结果；任何异常都不抛出，统一映射为中文原因。
    func check() async -> UpdateCheckResult {
        let current = Self.currentVersion
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await NetworkProxy.session(SettingsStore.shared.settings).data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failed(message: Self.message(forHTTPStatus: http.statusCode))
            }
            return Self.parse(data: data, current: current)
        } catch {
            return .failed(message: Self.message(for: error))
        }
    }

    // MARK: - 响应解析（防御式）

    /// 解析 GitHub Releases JSON。字段缺失或类型错误时逐项回退，绝不抛错。
    static func parse(data: Data, current: String) -> UpdateCheckResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(message: "服务器返回的数据无法解析")
        }
        let tag = (object["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latest = tag.isEmpty ? name : tag
        guard !latest.isEmpty else {
            return .failed(message: "未找到发布版本号")
        }
        // assets 仅用于诊断 / 未来扩展，缺失也不影响结果。
        let assets = (object["assets"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        _ = assets

        let html = (object["html_url"] as? String).flatMap { URL(string: $0) }
        let body = (object["body"] as? String) ?? ""
        let published = (object["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let display = displayVersion(latest)

        if isNewer(latest, than: current) {
            return .updateAvailable(current: current, latest: display, url: html,
                                    notes: body.isEmpty ? name : body, publishedAt: published)
        }
        return .upToDate(current: current)
    }

    // MARK: - 语义化版本比较（纯函数）

    /// 去掉前缀 `v` 后的展示用版本号。
    static func displayVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// 解析版本号为「数字段 + 预发布标识」。
    ///
    /// 容忍前缀 `v`、缺失段（`1.0` 等价 `1.0.0`）与非数字后缀（`1.2.3b` 取 `1.2.3`）。
    static func parseVersion(_ raw: String) -> (core: [Int], prerelease: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let split = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let corePart = split.first.map(String.init) ?? ""
        let prerelease = (split.count > 1 && !split[1].isEmpty) ? String(split[1]) : nil
        let core = corePart.split(separator: ".").map { segment -> Int in
            let digits = segment.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return (core, prerelease)
    }

    /// 语义化比较：`1.10.0 > 1.9.0`；忽略前缀 `v`；缺段按 0 补齐；
    /// 同一版本号的预发布版（`1.0.0-beta`）小于正式版（`1.0.0`）。
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parseVersion(lhs)
        let b = parseVersion(rhs)
        let count = max(a.core.count, b.core.count)
        for i in 0..<count {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, .some):
            return .orderedDescending
        case (.some, nil):
            return .orderedAscending
        case (.some(let x), .some(let y)):
            if x == y { return .orderedSame }
            return x < y ? .orderedAscending : .orderedDescending
        }
    }

    /// `candidate` 是否比 `current` 更新。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compareVersions(candidate, current) == .orderedDescending
    }

    // MARK: - 错误映射

    /// 把 HTTP 状态码映射为可读的中文原因。
    static func message(forHTTPStatus code: Int) -> String {
        switch code {
        case 403, 429:
            return "请求过于频繁（GitHub 限流），请稍后再试"
        case 404:
            return "未找到发布信息（仓库可能尚未发布版本）"
        case 500...599:
            return "服务器暂时不可用（HTTP \(code)），请稍后再试"
        default:
            return "检查更新失败（HTTP \(code)）"
        }
    }

    /// 把网络错误映射为可读的中文原因。
    static func message(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "检查更新失败：\(error.localizedDescription)"
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "网络不可用，请检查网络连接后重试"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "无法连接到更新服务器，请稍后重试"
        case .timedOut:
            return "连接更新服务器超时，请稍后重试"
        case .userAuthenticationRequired, .noPermissionsToReadFile:
            return "没有访问更新服务器的权限"
        default:
            return "检查更新失败：\(urlError.localizedDescription)"
        }
    }
}

extension UpdateCheckResult {
    /// 设置界面与 CLI 展示用的一行中文描述。
    var summary: String {
        switch self {
        case .upToDate:
            return "已是最新版本"
        case .updateAvailable(_, let latest, _, _, _):
            return "发现新版本 \(latest)"
        case .failed(let message):
            return "检查失败：\(message)"
        }
    }

    /// 发现的新版本（若可用）。
    var availableVersion: String? {
        if case .updateAvailable(_, let latest, _, _, _) = self { return latest }
        return nil
    }
}

/// 更新检查的界面状态与节流逻辑。
///
/// 网络请求本身在 ``UpdateChecker`` 内异步执行，不会阻塞主线程；
/// 本类型只负责节流（自动检查最多每 24 小时一次）、结果缓存与角标状态。
@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()
    /// 自动检查的最小间隔：24 小时。
    static let throttleInterval: TimeInterval = 24 * 60 * 60

    /// 是否有检查在进行中（用于按钮禁用与「检查中…」提示）。
    @Published private(set) var checking = false
    /// 最近一次手动 / 自动检查的结果。
    @Published private(set) var result: UpdateCheckResult?
    /// 是否在设置齿轮上显示「有新版本」角标。
    @Published private(set) var badgeVisible = false

    private init() {}

    /// 立即执行一次检查（用户点击「检查更新」）。
    func checkNow() async {
        await run(silent: false)
    }

    /// 启动时的自动检查：仅在开关打开且距上次检查超过 24 小时时执行；
    /// 静默进行，失败只在配置文件里记录时间戳，不产生任何错误界面。
    func autoCheckIfNeeded() async {
        let store = SettingsStore.shared
        guard store.settings.autoCheckUpdates else { return }
        let last = store.settings.lastUpdateCheck
        if last > 0, Date().timeIntervalSince1970 - last < Self.throttleInterval { return }
        await run(silent: true)
    }

    /// 打开「更新」分区后清除角标。
    func clearBadge() {
        badgeVisible = false
    }

    private func run(silent: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        let outcome = await UpdateChecker().check()
        // 无论成功失败都记录时间戳，避免反复重试触发限流。
        SettingsStore.shared.settings.lastUpdateCheck = Date().timeIntervalSince1970

        switch outcome {
        case .updateAvailable:
            result = outcome
            badgeVisible = true
        case .upToDate:
            if !silent { result = outcome }
            badgeVisible = false
        case .failed:
            if !silent { result = outcome }
        }
    }
}
