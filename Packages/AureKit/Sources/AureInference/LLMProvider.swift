import AureCore
import Foundation

public struct GenParams: Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    /// Number of alternatives to return per token (0 = no logprobs).
    public var topLogprobs: Int

    public init(temperature: Double = 0.2, topP: Double = 0.9, maxTokens: Int = 512, topLogprobs: Int = 0) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.topLogprobs = topLogprobs
    }
}

public struct LLMCompletion: Sendable, Equatable {
    public var text: String
    /// Per-token logprobs when requested and supported; empty otherwise.
    public var tokens: [TokenLogprob]

    public init(text: String, tokens: [TokenLogprob] = []) {
        self.text = text
        self.tokens = tokens
    }
}

/// A text-generation backend (local llama-server now; OpenAI later).
public protocol LLMProvider: Sendable {
    var id: String { get }
    /// `jsonSchema` is a JSON-serializable schema dictionary encoded as Data.
    /// `examples` are few-shot (user, assistant) turns sent before `user`.
    func generate(system: String, examples: [Prompt.Turn], user: String, jsonSchema: Data?,
                  params: GenParams) async throws -> LLMCompletion
}

extension LLMProvider {
    public func complete(system: String, examples: [Prompt.Turn] = [], user: String, jsonSchema: Data?,
                         params: GenParams) async throws -> String {
        try await generate(system: system, examples: examples, user: user, jsonSchema: jsonSchema, params: params).text
    }
}

/// Scripted provider for tests and previews.
public final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    public let id = "fake"
    private let lock = NSLock()
    private var responder: @Sendable (String, String) async throws -> LLMCompletion
    public private(set) var calls: [(system: String, user: String)] = []

    public init(responder: @escaping @Sendable (_ system: String, _ user: String) async throws -> String) {
        self.responder = { s, u in LLMCompletion(text: try await responder(s, u)) }
    }

    /// Answers with a full completion (text + token logprobs).
    public init(completion: @escaping @Sendable (_ system: String, _ user: String) async throws -> LLMCompletion) {
        self.responder = completion
    }

    /// Always answers with the given corrected text (and edits, as JSON, when given).
    public convenience init(corrected: String, edits: [ModelAnswer.Edit] = []) {
        let answer = edits.isEmpty
            ? corrected
            : String(decoding: try! JSONEncoder().encode(ModelAnswer(corrected: corrected, edits: edits)), as: UTF8.self)
        self.init { _, _ in answer }
    }

    public var callCount: Int { lock.withLock { calls.count } }

    public func generate(system: String, examples: [Prompt.Turn], user: String, jsonSchema: Data?,
                         params: GenParams) async throws -> LLMCompletion {
        lock.withLock { calls.append((system, user)) }
        try Task.checkCancellation()
        return try await responder(system, user)
    }
}
