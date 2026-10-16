import Foundation

/// 模型探测错误，消息为可读中文。
enum ModelDiscoveryError: LocalizedError {
    case missingKey
    case invalidURL(String)
    case http(Int, String)
    case decode(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "未配置 API Key，无法探测模型"
        case .invalidURL(let base):
            return "API 地址无效：\(base)"
        case .http(let status, let message):
            return "接口返回 HTTP \(status)：\(message)"
        case .decode(let detail):
            return "无法解析模型列表：\(detail)"
        case .empty:
            return "接口没有返回任何模型"
        }
    }
}

/// 按协议访问各家的模型列表接口，返回可用的模型 id。
enum ModelDiscovery {
    /// 探测模型列表。
    /// - Parameters:
    ///   - baseURL: API 地址（与设置中的一致）。
    ///   - apiKey: API Key。
    ///   - api: 接口协议（`APIType.rawValue`）。
    static func discover(baseURL: String, apiKey: String, api: String) async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ModelDiscoveryError.missingKey
        }
        let type = APIType.from(api)
        var request = try makeRequest(baseURL: baseURL, apiKey: apiKey, type: type)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelDiscoveryError.http(0, "无 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelDiscoveryError.http(http.statusCode, errorMessage(data, http.statusCode))
        }
        let ids = try parse(data, type: type)
        guard !ids.isEmpty else { throw ModelDiscoveryError.empty }
        return ids
    }

    // MARK: - 请求构造

    private static func makeRequest(baseURL: String, apiKey: String, type: APIType) throws -> URLRequest {
        let url: URL
        var headers: [String: String] = [:]
        switch type {
        case .openAICompletions, .openAIResponses:
            url = try openAIURL(baseURL: baseURL, path: "models")
            headers["Authorization"] = "Bearer \(apiKey)"
        case .anthropicMessages:
            url = try anthropicURL(baseURL: baseURL)
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        case .googleGenerativeAI:
            url = try googleURL(baseURL: baseURL, apiKey: apiKey)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// 与 `OpenAIRequestBuilder.resolveURL` 一致：去掉尾部斜杠，避免重复拼接后缀。
    private static func openAIURL(baseURL: String, path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base), url.scheme != nil, url.host != nil else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if suffix.isEmpty || base.hasSuffix("/" + suffix) { return url }
        guard let full = URL(string: base + "/" + suffix) else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        return full
    }

    /// 与 `AnthropicMessagesRequestBuilder.resolveURL` 一致：拼 `/v1/models`，避免重复 `/v1`。
    private static func anthropicURL(baseURL: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base), url.scheme != nil, url.host != nil else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        if base.hasSuffix("/v1/models") { return url }
        let full = base.hasSuffix("/v1") ? base + "/models" : base + "/v1/models"
        guard let fullURL = URL(string: full) else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        return fullURL
    }

    /// 与 `GoogleGenerativeAIRequestBuilder.resolveURL` 一致：仅在缺少版本段时补 `/v1beta`。
    private static func googleURL(baseURL: String, apiKey: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, var components = URLComponents(string: base),
              components.scheme != nil, components.host != nil else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        let hasVersion = components.path.hasSuffix("/v1beta") || components.path.hasSuffix("/v1")
        let versionPath = hasVersion ? "" : "/v1beta"
        components.path += "\(versionPath)/models"
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ModelDiscoveryError.invalidURL(baseURL)
        }
        return url
    }

    // MARK: - 响应解析

    private static func parse(_ data: Data, type: APIType) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ModelDiscoveryError.decode(snippet(data))
        }
        var ids: [String] = []
        switch type {
        case .googleGenerativeAI:
            if let root = object as? [String: Any], let models = root["models"] as? [[String: Any]] {
                ids = models.compactMap { $0["name"] as? String }
            } else if let array = object as? [[String: Any]] {
                ids = array.compactMap { $0["name"] as? String }
            } else if let array = object as? [String] {
                ids = array
            }
            ids = ids.map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
        default:
            if let root = object as? [String: Any], let items = root["data"] as? [[String: Any]] {
                ids = items.compactMap { $0["id"] as? String }
            } else if let array = object as? [[String: Any]] {
                ids = array.compactMap { $0["id"] as? String }
            } else if let array = object as? [String] {
                ids = array
            }
        }
        // 去重后按不区分大小写排序，便于搜索。
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func errorMessage(_ data: Data, _ status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msg = (obj["error"] as? [String: Any])?["message"] as? String { return msg }
            if let msg = obj["message"] as? String { return msg }
            if let msg = obj["error"] as? String { return msg }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "HTTP \(status)" : String(text.prefix(200))
    }

    private static func snippet(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "响应为空" : String(text.prefix(200))
    }
}

/// 已探测到的模型列表缓存（按协议 + 地址区分），便于不重新请求就再次打开选择器。
@MainActor
final class ModelDiscoveryStore: ObservableObject {
    static let shared = ModelDiscoveryStore()

    @Published private(set) var models: [String] = []
    private var cache: [String: [String]] = [:]

    private init() {}

    func cached(baseURL: String, api: String) -> [String]? {
        cache[key(baseURL: baseURL, api: api)]
    }

    func store(_ models: [String], baseURL: String, api: String) {
        cache[key(baseURL: baseURL, api: api)] = models
        self.models = models
    }

    private func key(baseURL: String, api: String) -> String {
        "\(api)|\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
