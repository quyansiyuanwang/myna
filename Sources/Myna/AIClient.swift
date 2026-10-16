import Foundation

enum AIError: LocalizedError {
    case badResponse(String)
    case api(String)
    var errorDescription: String? {
        switch self {
        case .badResponse(let s): return "响应异常: \(s)"
        case .api(let s): return "接口错误: \(s)"
        }
    }
}

/// OpenAI 兼容的 Chat Completions 客户端（DeepSeek 官方 API 等）
final class OpenAICompletionsClient {
    var settings: AppSettings
    init(_ settings: AppSettings) { self.settings = settings }

    private func makeRequest(stream: Bool, messages: [[String: Any]], tools: [[String: Any]]) throws -> URLRequest {
        guard !settings.apiKey.isEmpty else { throw AIError.api("未配置 API Key（请在设置里填写）") }
        guard let parsed = URL(string: settings.baseURL.trimmingCharacters(in: .whitespaces)),
              parsed.scheme != nil, parsed.host != nil else {
            throw AIError.api("API 地址无效：\(settings.baseURL)")
        }
        var url = parsed
        url.appendPathComponent("chat")
        url.appendPathComponent("completions")

        var body: [String: Any] = [
            "model": settings.model,
            "messages": messages,
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "frequency_penalty": settings.frequencyPenalty,
            "presence_penalty": settings.presencePenalty
        ]
        if stream { body["stream"] = true }
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180
        return req
    }

    private func errorMessage(_ data: Data, _ status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = (obj["error"] as? [String: Any])?["message"] as? String { return msg }
        return String(data: data, encoding: .utf8) ?? "HTTP \(status)"
    }

    /// 一次性（非流式）对话，返回 assistant 的原始 message 字典
    func chat(messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        let req = try makeRequest(stream: false, messages: messages, tools: tools)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse("无 HTTP 响应") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse(String(data: data, encoding: .utf8) ?? "无法解析")
        }
        if http.statusCode >= 400 { throw AIError.api(errorMessage(data, http.statusCode)) }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIError.badResponse("缺少 choices")
        }
        return message
    }

    /// 对 429 / 5xx 是否值得重试。
    private func isRetryable(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    private func backoffNanos(_ attempt: Int) -> UInt64 {
        let ms = min(4000, 300 * (1 << max(0, attempt - 1)))
        return UInt64(ms) * 1_000_000
    }

    /// 建立流式连接。对网络错误与 429/5xx 重试；一旦开始接收数据就不再重试，避免重复输出。
    private func openStream(messages: [[String: Any]], tools: [[String: Any]]) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            do {
                let req = try makeRequest(stream: true, messages: messages, tools: tools)
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse("无 HTTP 响应") }
                if http.statusCode >= 400 {
                    var data = Data()
                    for try await b in bytes { data.append(b) }
                    let err = AIError.api(errorMessage(data, http.statusCode))
                    if attempt < settings.maxRetries, isRetryable(status: http.statusCode) {
                        attempt += 1
                        try? await Task.sleep(nanoseconds: backoffNanos(attempt))
                        continue
                    }
                    throw err
                }
                return bytes
            } catch let e as AIError {
                throw e
            } catch {
                if error is CancellationError { throw error }
                if attempt >= settings.maxRetries { throw error }
                attempt += 1
                try? await Task.sleep(nanoseconds: backoffNanos(attempt))
            }
        }
    }

    /// 流式对话：边生成边回调文本增量，最终返回完整的 assistant message
    func chatStream(messages: [[String: Any]], tools: [[String: Any]],
                    onDelta: @escaping (String) -> Void,
                    onThinking: @escaping (String) -> Void = { _ in }) async throws -> [String: Any] {
        let bytes = try await openStream(messages: messages, tools: tools)

        var content = ""
        var toolCalls: [Int: [String: Any]] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                onThinking(r)
            }
            if let c = delta["content"] as? String, !c.isEmpty {
                content += c
                onDelta(c)
            }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let idx = (tc["index"] as? Int) ?? 0
                    var cur = toolCalls[idx] ?? ["id": "", "type": "function", "function": ["name": "", "arguments": ""]]
                    if let id = tc["id"] as? String, !id.isEmpty { cur["id"] = id }
                    if let fn = tc["function"] as? [String: Any] {
                        var cf = cur["function"] as? [String: Any] ?? ["name": "", "arguments": ""]
                        if let n = fn["name"] as? String, !n.isEmpty { cf["name"] = n }
                        if let a = fn["arguments"] as? String { cf["arguments"] = (cf["arguments"] as? String ?? "") + a }
                        cur["function"] = cf
                    }
                    toolCalls[idx] = cur
                }
            }
        }

        var msg: [String: Any] = ["role": "assistant"]
        msg["content"] = content.isEmpty ? NSNull() : content
        if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls.keys.sorted().map { toolCalls[$0]! } }
        return msg
    }
}

/// 带工具调用循环的智能体（内置兜底实现）
final class BuiltinAgent {
    var settings: AppSettings
    let client: OpenAICompletionsClient
    var messages: [[String: Any]] = []
    var onTool: ((String, String) -> Void)?
    var onDelta: ((String) -> Void)?
    var onThinking: ((String) -> Void)?
    var onText: ((String) -> Void)?

    init(settings: AppSettings = SettingsStore.shared.settings) {
        self.settings = settings
        self.client = OpenAICompletionsClient(settings)
        self.messages.append(["role": "system", "content": settings.systemPrompt])
    }

    func reset() {
        messages = [["role": "system", "content": settings.systemPrompt]]
    }

    /// 仅保留最近 `maxHistoryTurns` 轮用户消息（0 = 不限制）。
    private func trimHistory() {
        let max = settings.maxHistoryTurns
        guard max > 0, let sys = messages.first else { return }
        var userIndices: [Int] = []
        for (i, m) in messages.enumerated() where (m["role"] as? String) == "user" {
            userIndices.append(i)
        }
        guard userIndices.count > max else { return }
        let cut = userIndices[userIndices.count - max]
        messages = [sys] + Array(messages[cut...])
    }

    func ask(_ text: String) async throws -> String {
        client.settings = settings
        // 若系统提示被修改过，同步到当前会话
        if let sys = messages.first, (sys["content"] as? String) != settings.systemPrompt {
            messages[0] = ["role": "system", "content": settings.systemPrompt]
        }
        messages.append(["role": "user", "content": text])
        trimHistory()
        let tools = ToolRunner.definitions(disabled: settings.disabledTools)

        for _ in 0..<max(1, settings.maxToolRounds) {
            let msg = try await client.chatStream(messages: messages, tools: tools) { [weak self] chunk in
                self?.onDelta?(chunk)
            } onThinking: { [weak self] chunk in
                self?.onThinking?(chunk)
            }

            var assistant: [String: Any] = ["role": "assistant"]
            if let c = msg["content"] as? String, !c.isEmpty { assistant["content"] = c }
            else { assistant["content"] = NSNull() }
            if let tc = msg["tool_calls"] as? [[String: Any]] { assistant["tool_calls"] = tc }
            messages.append(assistant)

            guard let calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty else {
                let answer = (msg["content"] as? String) ?? ""
                onText?(answer)
                return answer.isEmpty ? "（模型没有返回内容）" : answer
            }

            for call in calls {
                let id = call["id"] as? String ?? ""
                let fn = call["function"] as? [String: Any]
                let name = fn?["name"] as? String ?? ""
                let argStr = fn?["arguments"] as? String ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argStr.utf8))) as? [String: Any] ?? [:]
                let result = ToolRunner.run(name: name, args: args)
                onTool?(name, result)
                messages.append(["role": "tool", "tool_call_id": id, "content": result])
            }
        }
        return "（工具调用轮次过多，已停止）"
    }
}
