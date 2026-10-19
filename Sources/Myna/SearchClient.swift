import Foundation

/// 搜索服务商。原始值即配置中的 `search_provider`。
enum SearchProvider: String, CaseIterable, Sendable {
    case none
    case tavily
    case brave
    case serper
    case custom

    /// 设置界面显示名。
    var label: String {
        switch self {
        case .none: return "关闭"
        case .tavily: return "Tavily"
        case .brave: return "Brave"
        case .serper: return "Serper"
        case .custom: return "自定义"
        }
    }

    /// 是否需要 API Key（自定义服务商允许留空）。
    var requiresKey: Bool { self != .none && self != .custom }

    /// 从配置字符串解析，未知值视为 `none`。
    static func from(_ raw: String) -> SearchProvider {
        SearchProvider(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .none
    }

    /// 各服务商的 Key 申请地址（设置界面说明用）。
    var keyPage: URL? {
        switch self {
        case .none: return nil
        case .tavily: return URL(string: "https://app.tavily.com/home")
        case .brave: return URL(string: "https://api.search.brave.com/app/keys")
        case .serper: return URL(string: "https://serper.dev/api-key")
        case .custom: return nil
        }
    }
}

/// 一条搜索结果。
struct SearchResult: Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
}

/// 一次搜索的完整结果。
struct SearchResponse: Equatable, Sendable {
    var results: [SearchResult]
    /// 服务商生成的综合答案（Tavily 等支持时才有）。
    var answer: String?

    /// 结果条数。
    var count: Int { results.count }
}

/// 搜索失败原因。`message` 为可直接展示给用户的中文。
enum SearchError: LocalizedError, Equatable {
    case notConfigured
    case invalidRequest(String)
    case http(Int, String)
    case network(String)
    case malformed(String)

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .notConfigured:
            return "尚未配置网络搜索。请打开 设置 → 工具 → 网络搜索，选择服务商并填写 API Key。"
        case .invalidRequest(let detail):
            return "搜索请求无效：\(detail)"
        case .http(let status, let detail):
            switch status {
            case 401, 403:
                return "API Key 无效或无权限（HTTP \(status)）\(detail.isEmpty ? "" : "：\(detail)")"
            case 429:
                return "请求过于频繁（限流）\(detail.isEmpty ? "" : "：\(detail)")"
            case 500...599:
                return "服务商暂时不可用（HTTP \(status)）\(detail.isEmpty ? "" : "：\(detail)")"
            default:
                return "搜索失败（HTTP \(status)）\(detail.isEmpty ? "" : "：\(detail)")"
            }
        case .network(let detail):
            return detail.isEmpty ? "网络请求失败，请检查网络或代理设置。" : "网络请求失败：\(detail)"
        case .malformed(let detail):
            return "服务商返回的数据无法解析：\(detail)"
        }
    }
}

/// 零依赖的网络搜索客户端。
///
/// 请求构造与响应解析都是纯静态函数（`makeRequest` / `parse`），
/// 便于离线自检（见 `myna search-check`）；`search` 负责真正发起请求。
enum SearchClient {
    /// 结果摘要的最大字符数。
    static let snippetLimit = 500

    // MARK: - 请求构造

    /// 按服务商构造 `URLRequest`。不发起任何网络请求。
    static func makeRequest(query: String, settings: AppSettings) throws -> URLRequest {
        let provider = SearchProvider.from(settings.searchProvider)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider != .none else { throw SearchError.notConfigured }
        guard !trimmed.isEmpty else { throw SearchError.invalidRequest("搜索词为空") }

        let key = settings.searchApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.requiresKey, key.isEmpty {
            throw SearchError.notConfigured
        }

        let limit = settings.effectiveSearchMaxResults
        let timeout = settings.effectiveSearchTimeout
        var request: URLRequest

        switch provider {
        case .none:
            throw SearchError.notConfigured

        case .tavily:
            guard let url = URL(string: "https://api.tavily.com/search") else {
                throw SearchError.invalidRequest("接口地址无效")
            }
            var body: [String: Any] = [
                "api_key": key,
                "query": trimmed,
                "max_results": limit,
                "include_answer": settings.searchIncludeAnswer
            ]
            body["search_depth"] = "basic"
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

        case .brave:
            guard var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else {
                throw SearchError.invalidRequest("接口地址无效")
            }
            components.queryItems = [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "count", value: String(limit))
            ]
            guard let url = components.url else { throw SearchError.invalidRequest("接口地址无效") }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

        case .serper:
            guard let url = URL(string: "https://google.serper.dev/search") else {
                throw SearchError.invalidRequest("接口地址无效")
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "X-API-KEY")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["q": trimmed, "num": limit])

        case .custom:
            let base = settings.searchBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else {
                throw SearchError.invalidRequest("自定义服务商需要填写接口地址")
            }
            if base.contains("{query}") {
                // 占位符形式：GET，关键词做 URL 编码后替换
                let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
                guard let url = URL(string: base.replacingOccurrences(of: "{query}", with: encoded)) else {
                    throw SearchError.invalidRequest("接口地址无效")
                }
                request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
            } else {
                guard let url = URL(string: base) else {
                    throw SearchError.invalidRequest("接口地址无效")
                }
                request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: ["query": trimmed, "max_results": limit])
            }
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }

        request.timeoutInterval = timeout
        return request
    }

    // MARK: - 响应解析

    /// 按服务商解析响应体。字段缺失或类型不符时逐项跳过，绝不抛错到崩溃。
    static func parse(_ data: Data, provider: SearchProvider) throws -> SearchResponse {
        guard !data.isEmpty else { throw SearchError.malformed("响应为空") }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw SearchError.malformed(String(data: data, encoding: .utf8)?.prefix(200).description ?? "非 JSON")
        }
        let root = object as? [String: Any] ?? [:]

        switch provider {
        case .none:
            throw SearchError.notConfigured

        case .tavily:
            let answer = clean(root["answer"])
            let items = root["results"] as? [[String: Any]] ?? []
            let results = items.compactMap { item -> SearchResult? in
                makeResult(title: item["title"], url: item["url"], snippet: item["content"])
            }
            return SearchResponse(results: results, answer: answer)

        case .brave:
            let web = root["web"] as? [String: Any]
            let items = web?["results"] as? [[String: Any]] ?? []
            let results = items.compactMap { item -> SearchResult? in
                makeResult(title: item["title"], url: item["url"], snippet: item["description"])
            }
            return SearchResponse(results: results, answer: nil)

        case .serper:
            let items = root["organic"] as? [[String: Any]] ?? []
            let results = items.compactMap { item -> SearchResult? in
                makeResult(title: item["title"], url: item["link"], snippet: item["snippet"])
            }
            return SearchResponse(results: results, answer: nil)

        case .custom:
            let items = firstArray(in: root, keys: ["results", "items", "organic", "data", "hits", "web_results"])
            let results = items.compactMap { item -> SearchResult? in
                makeResult(title: item["title"] ?? item["name"],
                           url: item["url"] ?? item["link"] ?? item["href"],
                           snippet: item["snippet"] ?? item["content"] ?? item["description"] ?? item["text"])
            }
            let answer = clean(root["answer"] ?? root["summary"] ?? root["result"])
            return SearchResponse(results: results, answer: answer)
        }
    }

    /// 在常见键名中找第一个数组（也接受 `{"data": {"results": [...]}}` 这类嵌套）。
    private static func firstArray(in root: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let items = root[key] as? [[String: Any]] { return items }
        }
        for key in keys {
            if let nested = root[key] as? [String: Any] {
                for inner in keys {
                    if let items = nested[inner] as? [[String: Any]] { return items }
                }
            }
        }
        return []
    }

    /// 组装一条结果：去空白、要求有 URL 或标题、截断摘要。
    private static func makeResult(title: Any?, url: Any?, snippet: Any?) -> SearchResult? {
        let title = clean(title) ?? ""
        let link = clean(url) ?? ""
        let body = clean(snippet) ?? ""
        guard !link.isEmpty || !title.isEmpty else { return nil }
        return SearchResult(title: title, url: link, snippet: String(body.prefix(snippetLimit)))
    }

    /// 把任意 JSON 值转成去空白的字符串；空串返回 nil。
    private static func clean(_ value: Any?) -> String? {
        let text: String
        switch value {
        case let s as String: text = s
        case let n as NSNumber: text = n.stringValue
        case let a as [Any]:
            // 少数服务商把摘要做成字符串数组
            text = a.compactMap { $0 as? String }.joined(separator: " ")
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 发起请求

    /// 执行一次搜索。网络错误统一映射为 ``SearchError``，不抛出底层 `URLError`。
    static func search(query: String, settings: AppSettings) async throws -> SearchResponse {
        let provider = SearchProvider.from(settings.searchProvider)
        let request = try makeRequest(query: query, settings: settings)
        let session = NetworkProxy.session(settings)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as SearchError {
            throw error
        } catch {
            throw SearchError.network(message(for: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw SearchError.http(status, serverMessage(data))
        }
        return try parse(data, provider: provider)
    }

    /// 从错误响应体里尽力提取一句可读说明。
    private static func serverMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(120).description ?? ""
        }
        for key in ["message", "error", "detail", "error_description"] {
            if let s = object[key] as? String, !s.isEmpty { return String(s.prefix(120)) }
            if let nested = object[key] as? [String: Any], let s = nested["message"] as? String {
                return String(s.prefix(120))
            }
        }
        return ""
    }

    /// 网络错误 → 中文提示。
    static func message(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "搜索失败：\(error.localizedDescription)"
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "网络不可用，请检查网络连接后重试"
        case .timedOut:
            return "搜索超时，请稍后重试或在设置中调大超时时间"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "无法连接到搜索服务商，请检查网络或代理设置"
        case .userAuthenticationRequired:
            return "API Key 无效或无权限"
        case .cancelled:
            return "搜索已取消"
        default:
            return "搜索失败：\(urlError.localizedDescription)"
        }
    }

    // MARK: - 结果渲染

    /// 把结果渲染成给模型 / 用户阅读的编号列表。
    static func render(_ response: SearchResponse, query: String, provider: SearchProvider) -> String {
        var lines: [String] = ["搜索「\(query)」（\(provider.label)）"]
        if let answer = response.answer, !answer.isEmpty {
            lines.append("")
            lines.append("综合答案：\(answer)")
        }
        guard !response.results.isEmpty else {
            lines.append("")
            lines.append("没有找到结果。")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        for (index, item) in response.results.enumerated() {
            lines.append("\(index + 1). \(item.title.isEmpty ? "（无标题）" : item.title)")
            if !item.url.isEmpty { lines.append("   \(item.url)") }
            if !item.snippet.isEmpty { lines.append("   \(item.snippet)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 工具适配

/// 供 `ToolRunner` 调用的同步桥接：真实联网搜索与网页正文抓取。
///
/// 工具执行体是同步的，这里用信号量做有界阻塞（带上限，绝不无限挂起）。
enum WebTools {
    /// 同步等待上限（略大于请求超时，留出解析时间）。
    private static func deadline(_ settings: AppSettings) -> DispatchTime {
        .now() + settings.effectiveSearchTimeout + 5
    }

    /// 联网搜索；未配置服务商时返回可读提示而不是打开浏览器。
    static func search(query: String) -> String {
        let settings = SettingsStore.shared.settings
        let provider = SearchProvider.from(settings.searchProvider)
        guard provider != .none else {
            return "尚未配置搜索服务商。请在「设置 → 工具 → 网络搜索」中选择 Tavily / Brave / Serper 或自定义接口并填入 API Key。"
        }
        let sem = DispatchSemaphore(value: 0)
        var output = "搜索超时"
        Task.detached {
            defer { sem.signal() }
            do {
                let response = try await SearchClient.search(query: query, settings: settings)
                output = SearchClient.render(response, query: query, provider: provider)
            } catch {
                output = "搜索失败：\((error as? SearchError)?.message ?? error.localizedDescription)"
            }
        }
        if sem.wait(timeout: deadline(settings)) == .timedOut { return "搜索超时，请检查网络或代理设置。" }
        return output
    }

    /// 抓取网页正文并转成纯文本。
    static func fetch(url: String) -> String {
        let settings = SettingsStore.shared.settings
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "网址无效，需要以 http:// 或 https:// 开头。"
        }
        let sem = DispatchSemaphore(value: 0)
        var output = "抓取超时"
        Task.detached {
            defer { sem.signal() }
            do {
                let text = try await SearchClient.fetchText(url: parsed, settings: settings)
                output = text.isEmpty ? "页面没有可读正文。" : text
            } catch {
                output = "抓取失败：\((error as? SearchError)?.message ?? error.localizedDescription)"
            }
        }
        if sem.wait(timeout: deadline(settings)) == .timedOut { return "抓取超时，请检查网络或代理设置。" }
        return output
    }
}

extension SearchClient {
    /// 抓取网页并转成可读纯文本：去掉脚本/样式/标签，压缩空白，超长截断。
    static func fetchText(url: URL, settings: AppSettings, limit: Int = 8000) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = settings.effectiveSearchTimeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Myna/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let session = NetworkProxy.session(settings)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as SearchError {
            throw error
        } catch {
            throw SearchError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SearchError.http(http.statusCode, "服务器返回 \(http.statusCode)")
        }
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return plainText(fromHTML: raw, limit: limit)
    }

    /// 极简 HTML → 纯文本：不引入任何依赖，只做标签剥离与空白归一。
    static func plainText(fromHTML html: String, limit: Int = 8000) -> String {
        var text = html
        // 去掉整段 script / style / head / svg
        for tag in ["script", "style", "head", "svg", "noscript"] {
            while let start = text.range(of: "<\(tag)", options: .caseInsensitive),
                  let end = text.range(of: "</\(tag)>", options: .caseInsensitive, range: start.lowerBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        // 块级标签换行，其余标签删除
        for tag in ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article"] {
            text = text.replacingOccurrences(of: "<\(tag)", with: "\n<\(tag)", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // 常见实体
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&mdash;": "—"]
        for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
        // 压缩空白与空行
        text = text.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > limit {
            let cut = text.prefix(limit)
            return cut + "\n\n…（正文过长，已截断）"
        }
        return text
    }
}
