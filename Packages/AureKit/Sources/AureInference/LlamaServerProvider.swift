import AureCore
import Foundation

/// Talks to a llama-server over its OpenAI-compatible HTTP API.
public struct LlamaServerProvider: LLMProvider {
    public let id = "llama-server"
    public let baseURL: URL
    public let apiKey: String?
    let session: URLSession

    public init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func generate(system: String, examples: [Prompt.Turn], user: String, jsonSchema: Data?,
                         params: GenParams) async throws -> LLMCompletion {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        var body: [String: Any] = [
            "messages": [["role": "system", "content": system]]
                + examples.flatMap { [["role": "user", "content": $0.user], ["role": "assistant", "content": $0.assistant]] }
                + [["role": "user", "content": user]],
            "temperature": params.temperature,
            "top_p": params.topP,
            "max_tokens": params.maxTokens,
            "stream": false,
            "cache_prompt": true,
            // Qwen3: keep the chat template in non-thinking mode.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        if params.topLogprobs > 0 {
            body["logprobs"] = true
            body["top_logprobs"] = params.topLogprobs
        }
        if !params.banned.isEmpty {
            var bias: [String: Double] = [:]
            for s in params.banned {
                if let id = await singleToken(s) { bias[String(id)] = -100 }
            }
            if !bias.isEmpty { body["logit_bias"] = bias }
        }
        if let jsonSchema, let schema = try? JSONSerialization.jsonObject(with: jsonSchema) {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "aure", "schema": schema]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch is CancellationError {
            throw AureError.cancelled
        } catch let e as URLError where e.code == .cancelled {
            throw AureError.cancelled
        } catch {
            throw AureError.server(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw AureError.server("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AureError.server("HTTP \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        struct Completion: Decodable {
            struct Alt: Decodable { var bytes: [UInt8]?; var token: String?; var logprob: Double }
            struct Tok: Decodable {
                var bytes: [UInt8]?
                var token: String?
                var logprob: Double
                var top_logprobs: [Alt]?
            }
            struct Logprobs: Decodable { var content: [Tok]? }
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
                var logprobs: Logprobs?
            }
            var choices: [Choice]
        }
        guard let choice = try JSONDecoder().decode(Completion.self, from: data).choices.first,
              let content = choice.message.content else {
            throw AureError.invalidModelOutput("empty completion")
        }
        let tokens = (choice.logprobs?.content ?? []).map { t in
            TokenLogprob(bytes: t.bytes ?? Array((t.token ?? "").utf8), logprob: t.logprob,
                         top: (t.top_logprobs ?? []).map {
                             TokenLogprob.Alternative(bytes: $0.bytes ?? Array(($0.token ?? "").utf8), logprob: $0.logprob)
                         })
        }
        return LLMCompletion(text: content, tokens: tokens)
    }

    private static let tokenIDs = TokenIDCache()

    /// The token id when `text` is exactly one token for the loaded model. A string
    /// split into byte tokens is never banned: those bytes are shared by other
    /// characters (curly quotes, ellipses).
    func singleToken(_ text: String) async -> Int? {
        let key = baseURL.absoluteString + "\u{0}" + text
        if let cached = await Self.tokenIDs.get(key) { return cached }
        var req = URLRequest(url: baseURL.appendingPathComponent("tokenize"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": text])
        struct Tokens: Decodable { var tokens: [Int] }
        guard let (data, _) = try? await session.data(for: req),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data).tokens else { return nil }
        let id = tokens.count == 1 ? tokens[0] : nil
        await Self.tokenIDs.set(key, id)
        return id
    }
}

private actor TokenIDCache {
    private var ids: [String: Int?] = [:]
    func get(_ key: String) -> Int?? { ids[key] }
    func set(_ key: String, _ id: Int?) { ids[key] = id }
}
