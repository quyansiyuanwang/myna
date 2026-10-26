import Foundation
import PiKit

/// 代理类型。
enum ProxyKind: String, CaseIterable, Sendable {
    case http, https, socks5

    /// 设置界面显示名。
    var label: String {
        switch self {
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .socks5: return "SOCKS5"
        }
    }

    /// `connectionProxyDictionary` 中的类型键（macOS 上取值相同）。
    var proxyTypeKey: String {
        switch self {
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .socks5: return "SOCKS"
        }
    }

    /// 从配置字符串解析，未知值回退 `http`。
    static func from(_ raw: String) -> ProxyKind {
        ProxyKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .http
    }
}

/// 按 App 设置生成带代理的 `URLSession` / PiAI 传输层。
///
/// 全部为纯函数：不读写全局状态，可离线断言（见 `myna proxy-check`）。
/// 代理关闭或主机 / 端口非法时返回 `.default` 配置且不带代理字典。
enum NetworkProxy {

    /// 归一化后的代理端口（1…65535，非法返回 nil）。
    static func port(_ settings: AppSettings) -> Int? {
        guard settings.proxyPort >= 1, settings.proxyPort <= 65_535 else { return nil }
        return settings.proxyPort
    }

    /// 归一化后的代理主机（去空白，非法返回 nil）。
    static func host(_ settings: AppSettings) -> String? {
        let host = settings.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
    }

    /// 绕过列表：按逗号 / 空白切分并去空。
    static func bypassList(_ settings: AppSettings) -> [String] {
        settings.proxyBypass
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 是否实际启用代理（开关打开且主机 / 端口有效）。
    static func isActive(_ settings: AppSettings) -> Bool {
        settings.proxyEnabled && host(settings) != nil && port(settings) != nil
    }

    /// 构造 `connectionProxyDictionary`；未启用代理时返回空字典。
    ///
    /// 形如：
    /// ```
    /// ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
    ///  "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890]
    /// ```
    /// HTTP 类型会同时设置 HTTP 与 HTTPS 两套键（同一端口通常两者通用），
    /// HTTPS 类型只设置 HTTPS 键，SOCKS5 只设置 SOCKS 键。
    static func proxyDictionary(_ settings: AppSettings) -> [String: Any] {
        guard isActive(settings), let host = host(settings), let port = port(settings) else { return [:] }
        let kind = ProxyKind.from(settings.proxyType)
        var dict: [String: Any] = [:]
        let username = settings.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = settings.proxyPassword

        // 认证键名按 CFNetwork 约定：HTTP 用 HTTPProxyUsername/HTTPProxyPassword，
        // SOCKS 用 SOCKSUser/SOCKSPassword（写成 HTTPUser 这类名字不会生效）。
        func apply(_ type: String, userKey: String, passwordKey: String) {
            dict["\(type)Enable"] = 1
            dict["\(type)Proxy"] = host
            dict["\(type)Port"] = port
            if !username.isEmpty {
                dict[userKey] = username
                dict[passwordKey] = password
            }
        }

        switch kind {
        case .http:
            apply("HTTP", userKey: "HTTPProxyUsername", passwordKey: "HTTPProxyPassword")
            apply("HTTPS", userKey: "HTTPSProxyUsername", passwordKey: "HTTPSProxyPassword")
        case .https:
            apply("HTTPS", userKey: "HTTPSProxyUsername", passwordKey: "HTTPSProxyPassword")
        case .socks5:
            apply("SOCKS", userKey: "SOCKSUser", passwordKey: "SOCKSPassword")
        }

        let bypass = bypassList(settings)
        if !bypass.isEmpty { dict["ExceptionsList"] = bypass }
        return dict
    }

    /// `.default` 配置 + 代理字典。
    static func sessionConfiguration(_ settings: AppSettings) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let dict = proxyDictionary(settings)
        if !dict.isEmpty { config.connectionProxyDictionary = dict }
        return config
    }

    /// 普通 `URLSession` 调用方（搜索、网页抓取、更新检查）使用。
    static func session(_ settings: AppSettings) -> URLSession {
        URLSession(configuration: sessionConfiguration(settings))
    }

    /// PiAI 非流式传输层。
    static func httpClient(_ settings: AppSettings) -> any HTTPClient {
        CanonicalJSONHTTPClient(
            base: URLSessionHTTPClient(configuration: sessionConfiguration(settings))
        )
    }

    /// PiAI 流式传输层。
    static func streamingClient(_ settings: AppSettings) -> any StreamingHTTPClient {
        CanonicalJSONStreamingClient(
            base: URLSessionStreamingHTTPClient(configuration: sessionConfiguration(settings))
        )
    }
}

/// 把 JSON 请求体重新编码为「键有序」的稳定形式。
///
/// Swift 的 `JSONEncoder` 对 `[String: ...]` 不保证键顺序；实测同一个工具
/// Schema 在每次请求里的键顺序都不同。服务端若按请求体中的 tools 文本做前缀
/// 缓存，就会出现「每一请求的前缀都不一样」→ 命中率恒为 0。
/// 这里只做语法层面的规范化：解析后按 key 排序重新编码，语义完全不变。
enum CanonicalJSONBody {
    static func rewrite(_ request: URLRequest) -> URLRequest {
        guard let body = request.httpBody, !body.isEmpty else { return request }
        guard let object = try? JSONSerialization.jsonObject(with: body),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            return request
        }
        var copy = request
        copy.httpBody = data
        return copy
    }
}

private struct CanonicalJSONHTTPClient: HTTPClient {
    let base: any HTTPClient

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await base.send(CanonicalJSONBody.rewrite(request))
    }
}

private struct CanonicalJSONStreamingClient: StreamingHTTPClient {
    let base: any StreamingHTTPClient

    func stream(_ request: URLRequest) async throws -> HTTPStream {
        try await base.stream(CanonicalJSONBody.rewrite(request))
    }
}
