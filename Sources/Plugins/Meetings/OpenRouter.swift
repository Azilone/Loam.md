import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the pipeline asks of the models. `OpenRouterClient` in the app; a fake in tests.
public protocol MeetingAI: Sendable {
    /// Transcribes one chunk; `format` is the file's extension (`mp3`, `flac`, `wav`).
    func transcribe(_ audio: Data, format: String, model: String, language: String, diarize: Bool) async throws -> SttResult
    /// One chat completion; `schema` asks for JSON in that shape, `json` for any JSON object. Returns the text and its
    /// cost in US dollars, when known.
    func chat(model: String, system: String, user: String, json: Bool, schema: [String: Any]?, maxTokens: Int?) async throws
        -> (text: String, cost: Double)
}

public struct AIError: Error, LocalizedError, Equatable {
    public let message: String
    /// HTTP status, 0 for a network failure.
    public let status: Int

    public init(_ message: String, status: Int) {
        self.message = message
        self.status = status
    }

    public var errorDescription: String? { message }
    var isRetryable: Bool { status == 0 || status == 408 || status == 429 || status >= 500 }
}

/// Where the keys come from: the Keychain on a Mac, else `OPENROUTER_API_KEY` and `ANTHROPIC_API_KEY`.
public protocol MeetingKeys: Sendable {
    func openRouterKey() -> String?
    func anthropicKey() -> String?
}

/// OpenRouter for transcription and most models; a model id without a vendor prefix (`claude-haiku-5-5`) goes
/// straight to the Claude API with its own key.
public struct OpenRouterClient: MeetingAI {
    static let base = URL(string: "https://openrouter.ai/api/v1")!
    static let anthropic = URL(string: "https://api.anthropic.com/v1")!
    /// Claude API price per million tokens (input, output), for the cost shown only.
    static let anthropicPrices: [String: (Double, Double)] = ["claude-haiku-5-5": (0.1, 0.5)]

    let keys: MeetingKeys
    let session: URLSession

    public init(keys: MeetingKeys, session: URLSession = .shared) {
        self.keys = keys
        self.session = session
    }

    public func transcribe(_ audio: Data, format: String, model: String, language: String, diarize: Bool) async throws -> SttResult {
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio.base64EncodedString(), "format": format],
            "response_format": "verbose_json",
            "timestamp_granularities": ["segment"],
        ]
        if !language.isEmpty { body["language"] = language }
        if diarize { body["provider"] = ["options": ["azure": ["diarization": ["enabled": true]]]] }
        let data = try await retrying { try await post(Self.base.appendingPathComponent("audio/transcriptions"), body) }
        do {
            return try JSONDecoder().decode(SttResult.self, from: data)
        } catch {
            throw AIError("The transcription could not be read: \(String(decoding: data.prefix(200), as: UTF8.self))", status: 502)
        }
    }

    public func chat(model: String, system: String, user: String, json: Bool, schema: [String: Any]?, maxTokens: Int?) async throws
        -> (text: String, cost: Double) {
        if Self.usesClaudeAPI(model) {
            return try await chatClaude(model: model, system: system, user: user, json: json, schema: schema, maxTokens: maxTokens)
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2,
            "usage": ["include": true],
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if let schema {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "strict": true, "schema": schema]]
            // Only providers that really enforce the schema.
            body["provider"] = ["require_parameters": true]
        } else if json {
            body["response_format"] = ["type": "json_object"]
        }
        let data = try await retrying { try await post(Self.base.appendingPathComponent("chat/completions"), body) }
        let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((reply?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        guard let text = message?["content"] as? String, !text.isEmpty else { throw AIError("The model sent an empty reply.", status: 502) }
        let cost = ((reply?["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue ?? 0
        return (text, cost)
    }

    static func usesClaudeAPI(_ model: String) -> Bool { !model.isEmpty && !model.contains("/") }

    private func chatClaude(model: String, system: String, user: String, json: Bool, schema: [String: Any]?, maxTokens: Int?) async throws
        -> (text: String, cost: Double) {
        guard let key = keys.anthropicKey(), !key.isEmpty else {
            throw AIError("The model \(model) goes to the Claude API, which needs its key (Set up meeting recorder).", status: 401)
        }
        var prompt = system
        // No strict mode on this route: the schema goes into the prompt and the caller checks the reply.
        if let schema, let text = try? JSONSerialization.data(withJSONObject: schema) {
            prompt += "\n\nReply with a single JSON object that follows this JSON schema, and nothing else:\n" + String(decoding: text, as: UTF8.self)
        } else if json {
            prompt += "\n\nReply with a single JSON object and nothing else."
        }
        let body: [String: Any] = [
            "model": model, "max_tokens": maxTokens ?? 8192, "temperature": 0.2, "system": prompt,
            "messages": [["role": "user", "content": user]],
        ]
        let data = try await retrying {
            var request = URLRequest(url: Self.anthropic.appendingPathComponent("messages"))
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return try await send(request, body, service: "Claude API")
        }
        let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = ((reply?["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError("The model sent an empty reply.", status: 502) }
        let usage = reply?["usage"] as? [String: Any]
        let (input, output) = Self.anthropicPrices[model] ?? (0, 0)
        let tokensIn = (usage?["input_tokens"] as? NSNumber)?.doubleValue ?? 0
        let tokensOut = (usage?["output_tokens"] as? NSNumber)?.doubleValue ?? 0
        return (text, (tokensIn * input + tokensOut * output) / 1_000_000)
    }

    private func post(_ url: URL, _ body: [String: Any]) async throws -> Data {
        guard let key = keys.openRouterKey(), !key.isEmpty else {
            throw AIError("No OpenRouter key: add one with Set up meeting recorder (or meetings.set-key).", status: 401)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/Azilone/loam", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Loam", forHTTPHeaderField: "X-Title")
        return try await send(request, body, service: "OpenRouter")
    }

    private func send(_ request: URLRequest, _ body: [String: Any], service: String) async throws -> Data {
        var request = request
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await perform(request)
        guard status < 400 else {
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (reply?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError("\(service) \(status): \(message)", status: status)
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: AIError("Network error: \(error.localizedDescription)", status: 0))
                } else {
                    continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                }
            }.resume()
        }
    }

    /// Tries a call four times, 2, 4 then 8 seconds apart, when the failure may pass (network, rate limit, 5xx).
    private func retrying(_ call: () async throws -> Data) async throws -> Data {
        var delay: UInt64 = 2_000_000_000
        for attempt in 1... {
            do {
                return try await call()
            } catch let error as AIError where error.isRetryable && attempt < 4 {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        fatalError("unreachable")
    }

    /// Whether a key works, and how much credit is left, in one sentence.
    public static func check(openRouterKey key: String, session: URLSession = .shared) async -> (ok: Bool, message: String) {
        var request = URLRequest(url: base.appendingPathComponent("key"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let client = OpenRouterClient(keys: StaticKeys(openRouter: key), session: session)
        guard let (data, status) = try? await client.perform(request) else { return (false, "OpenRouter cannot be reached.") }
        if status == 401 || status == 403 { return (false, "OpenRouter refused this key.") }
        if status >= 400 { return (false, "OpenRouter answered \(status).") }
        let info = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any]
        if let remaining = (info?["limit_remaining"] as? NSNumber)?.doubleValue {
            return (true, String(format: "Key works: $%.2f left on its limit.", remaining))
        }
        var credits = URLRequest(url: base.appendingPathComponent("credits"))
        credits.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let (data, status) = try? await client.perform(credits), status < 400,
           let info = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any],
           let total = (info["total_credits"] as? NSNumber)?.doubleValue {
            let used = (info["total_usage"] as? NSNumber)?.doubleValue ?? 0
            return (true, String(format: "Key works: $%.2f of credit left.", total - used))
        }
        return (true, "Key works.")
    }
}

/// Keys given as values: the CLI's environment, a key being checked, tests.
public struct StaticKeys: MeetingKeys {
    let openRouter: String?
    let anthropic: String?

    public init(openRouter: String? = nil, anthropic: String? = nil) {
        self.openRouter = openRouter
        self.anthropic = anthropic
    }

    public func openRouterKey() -> String? { openRouter }
    public func anthropicKey() -> String? { anthropic }
}
