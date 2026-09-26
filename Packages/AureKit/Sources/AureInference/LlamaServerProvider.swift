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

    public func complete(system: String, user: String, jsonSchema: Data?, params: GenParams) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": params.temperature,
            "top_p": params.topP,
            "max_tokens": params.maxTokens,
            "stream": false,
            "cache_prompt": true,
            // Qwen3: keep the chat template in non-thinking mode.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
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
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
            }
            var choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Completion.self, from: data).choices.first?.message.content else {
            throw AureError.invalidModelOutput("empty completion")
        }
        return content
    }
}
