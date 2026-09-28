import AureCore
import Foundation

/// A model the local Ollama server has pulled (`GET /api/tags`).
public struct OllamaModel: Identifiable, Hashable, Sendable {
    /// The name users type in `ollama run`, e.g. "qwen3:4b" or "hf.co/Qwen/Qwen3-4B-GGUF:Q4_K_M".
    public var name: String
    public var bytes: Int64
    public var family: String?
    public var parameterSize: String?
    public var quantization: String?
    /// "completion", "thinking", "embedding", "vision", ... (empty on servers too old to report them).
    public var capabilities: [String]

    public var id: String { name }

    public init(name: String, bytes: Int64, family: String? = nil, parameterSize: String? = nil,
                quantization: String? = nil, capabilities: [String] = []) {
        self.name = name; self.bytes = bytes; self.family = family; self.parameterSize = parameterSize
        self.quantization = quantization; self.capabilities = capabilities
    }

    /// Embedding-only models cannot answer chat prompts.
    public var canChat: Bool { capabilities.isEmpty || capabilities.contains("completion") }
}

/// Talks to a local Ollama server (https://ollama.com) over its native HTTP API.
/// Used instead of the bundled llama-server where only Ollama may be installed.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = OllamaClient.defaultBaseURL(), session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `OLLAMA_HOST` when set ("host:port" or a URL), else http://127.0.0.1:11434.
    public static func defaultBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let fallback = URL(string: "http://127.0.0.1:11434")!
        guard var host = environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return fallback }
        if !host.contains("://") { host = "http://" + host }
        guard var c = URLComponents(string: host), let h = c.host, !h.isEmpty else { return fallback }
        // The server listens on every interface for 0.0.0.0; connect locally.
        if h == "0.0.0.0" { c.host = "127.0.0.1" }
        if c.port == nil { c.port = 11434 }
        return c.url ?? fallback
    }

    /// The Ollama menu bar app, when installed (a Homebrew install may be the CLI only).
    public static func appURL() -> URL? {
        let fm = FileManager.default
        return [URL(fileURLWithPath: "/Applications/Ollama.app"),
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ollama.app")]
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// True when the Ollama app or CLI is on this Mac (running or not).
    public static func isInstalled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let fm = FileManager.default
        if appURL() != nil { return true }
        let path = environment["PATH"] ?? ""
        return (path.split(separator: ":").map(String.init) + ["/usr/local/bin", "/opt/homebrew/bin"])
            .contains { fm.isExecutableFile(atPath: $0 + "/ollama") }
    }

    /// The server version, or nil when it is not running.
    public func version() async -> String? {
        struct V: Decodable { var version: String }
        guard let data = try? await get("api/version", timeout: 2) else { return nil }
        return (try? JSONDecoder().decode(V.self, from: data))?.version
    }

    public func models() async throws -> [OllamaModel] {
        try Self.parseModels(try await get("api/tags", timeout: 5))
    }

    static func parseModels(_ data: Data) throws -> [OllamaModel] {
        struct Tags: Decodable {
            struct Details: Decodable { var family: String?; var parameter_size: String?; var quantization_level: String? }
            struct Model: Decodable { var name: String; var size: Int64?; var details: Details?; var capabilities: [String]? }
            var models: [Model]
        }
        return try JSONDecoder().decode(Tags.self, from: data).models.map {
            OllamaModel(name: $0.name, bytes: $0.size ?? 0, family: $0.details?.family,
                        parameterSize: $0.details?.parameter_size, quantization: $0.details?.quantization_level,
                        capabilities: $0.capabilities ?? [])
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// A provider for `model`. Reads the model's chat template once so thinking
    /// models (Qwen3) can be kept in non-thinking mode.
    public func provider(for model: String) async throws -> OllamaProvider {
        struct Show: Decodable { var template: String?; var capabilities: [String]? }
        let data = try await post("api/show", ["model": model], timeout: 30)
        let show = try? JSONDecoder().decode(Show.self, from: data)
        let thinks = show?.capabilities?.contains("thinking") ?? false
        return OllamaProvider(baseURL: baseURL, model: model, thinks: thinks,
                              prefill: thinks ? OllamaProvider.nonThinkingPrefill(template: show?.template ?? "") : nil,
                              session: session)
    }

    /// Downloads `model` (`ollama pull`), reporting progress 0...1.
    public func pull(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AureError.server("Ollama could not pull \(model)")
        }
        struct Status: Decodable { var status: String?; var total: Int64?; var completed: Int64?; var error: String? }
        for try await line in bytes.lines {
            guard let s = try? JSONDecoder().decode(Status.self, from: Data(line.utf8)) else { continue }
            if let error = s.error { throw AureError.server(error) }
            if let total = s.total, total > 0, let done = s.completed { progress(Double(done) / Double(total)) }
            if s.status == "success" { progress(1); return }
        }
        throw AureError.server("Ollama stopped before \(model) finished downloading")
    }

    /// Unloads `model` from memory now instead of after its keep-alive.
    public func unload(_ model: String) async {
        _ = try? await post("api/generate", ["model": model, "keep_alive": 0], timeout: 10)
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = timeout
        return try await send(req)
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw AureError.server("Ollama is not running (\(error.localizedDescription))")
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AureError.server("Ollama: \(OllamaProvider.errorMessage(data))")
        }
        return data
    }
}

/// Generates text with a model served by Ollama (`POST /api/chat`).
///
/// Differences from llama-server: Ollama has no logit bias, so `GenParams.banned`
/// is ignored (the prompt still asks for no em dashes); older servers return no
/// logprobs, which confidence scoring tolerates.
public struct OllamaProvider: LLMProvider {
    public let id = "ollama"
    public let baseURL: URL
    public let model: String
    /// The model can think; Aure always asks it not to (`think: false`).
    public let thinks: Bool
    /// Start of the assistant turn that skips thinking, for templates that open `<think>` themselves.
    public let prefill: String?
    let session: URLSession

    /// Matches llama-server's per-slot context, so prompts behave the same on both engines.
    static let contextSize = 4096
    /// Keep the model loaded between checks; Ollama's default (5 min) makes the next check reload it.
    static let keepAlive = "30m"

    public init(baseURL: URL, model: String, thinks: Bool = false, prefill: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.thinks = thinks
        self.prefill = prefill
        self.session = session
    }

    /// Qwen3-style templates end the prompt with `<think>` and ignore `think: false`,
    /// so the answer would start with reasoning. Prefilling an empty think block is what
    /// llama-server's `enable_thinking: false` does.
    static func nonThinkingPrefill(template: String) -> String? {
        template.contains("<think>") ? "<think>\n\n</think>\n\n" : nil
    }

    func body(system: String, examples: [Prompt.Turn], user: String, jsonSchema: Data?, params: GenParams) -> [String: Any] {
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for e in examples {
            messages.append(["role": "user", "content": e.user])
            messages.append(["role": "assistant", "content": e.assistant])
        }
        messages.append(["role": "user", "content": user])
        if let prefill { messages.append(["role": "assistant", "content": prefill]) }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "keep_alive": Self.keepAlive,
            "options": [
                "temperature": params.temperature,
                "top_p": params.topP,
                "num_predict": params.maxTokens,
                "num_ctx": Self.contextSize,
            ] as [String: Any],
        ]
        // Only thinking models need it; others have nothing to turn off.
        if thinks { body["think"] = false }
        if params.topLogprobs > 0 {
            body["logprobs"] = true
            body["top_logprobs"] = params.topLogprobs
        }
        if let jsonSchema, let schema = try? JSONSerialization.jsonObject(with: jsonSchema) {
            body["format"] = schema
        }
        return body
    }

    public func generate(system: String, examples: [Prompt.Turn], user: String, jsonSchema: Data?,
                         params: GenParams) async throws -> LLMCompletion {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        // The first request after a switch also loads the model.
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(system: system, examples: examples, user: user,
                                                                       jsonSchema: jsonSchema, params: params))
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch is CancellationError {
            throw AureError.cancelled
        } catch let e as URLError where e.code == .cancelled {
            throw AureError.cancelled
        } catch {
            throw AureError.server("Ollama is not running (\(error.localizedDescription))")
        }
        guard let http = resp as? HTTPURLResponse else { throw AureError.server("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AureError.server("Ollama HTTP \(http.statusCode): \(Self.errorMessage(data))")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> LLMCompletion {
        struct Alt: Decodable { var token: String?; var bytes: [UInt8]?; var logprob: Double }
        struct Tok: Decodable { var token: String?; var bytes: [UInt8]?; var logprob: Double; var top_logprobs: [Alt]? }
        struct Chat: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
            var logprobs: [Tok]?
        }
        let chat = try JSONDecoder().decode(Chat.self, from: data)
        guard let content = chat.message?.content, !content.isEmpty else {
            throw AureError.invalidModelOutput("empty completion")
        }
        let tokens = (chat.logprobs ?? []).map { t in
            TokenLogprob(bytes: t.bytes ?? Array((t.token ?? "").utf8), logprob: t.logprob,
                         top: (t.top_logprobs ?? []).map {
                             TokenLogprob.Alternative(bytes: $0.bytes ?? Array(($0.token ?? "").utf8), logprob: $0.logprob)
                         })
        }
        return LLMCompletion(text: content, tokens: tokens)
    }

    /// Ollama errors are `{"error": "..."}`.
    static func errorMessage(_ data: Data) -> String {
        struct E: Decodable { var error: String }
        return (try? JSONDecoder().decode(E.self, from: data))?.error ?? String(decoding: data.prefix(300), as: UTF8.self)
    }
}
