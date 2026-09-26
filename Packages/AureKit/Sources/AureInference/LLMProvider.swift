import AureCore
import Foundation

public struct GenParams: Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(temperature: Double = 0.2, topP: Double = 0.9, maxTokens: Int = 512) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }
}

/// A text-generation backend (local llama-server now; OpenAI later).
public protocol LLMProvider: Sendable {
    var id: String { get }
    /// `jsonSchema` is a JSON-serializable schema dictionary encoded as Data.
    /// `examples` are few-shot (user, assistant) turns sent before `user`.
    func complete(system: String, examples: [Prompt.Turn], user: String, jsonSchema: Data?,
                  params: GenParams) async throws -> String
}

extension LLMProvider {
    public func complete(system: String, user: String, jsonSchema: Data?, params: GenParams) async throws -> String {
        try await complete(system: system, examples: [], user: user, jsonSchema: jsonSchema, params: params)
    }
}

/// Scripted provider for tests and previews.
public final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    public let id = "fake"
    private let lock = NSLock()
    private var responder: @Sendable (String, String) async throws -> String
    public private(set) var calls: [(system: String, user: String)] = []

    public init(responder: @escaping @Sendable (_ system: String, _ user: String) async throws -> String) {
        self.responder = responder
    }

    /// Always answers with the given corrected text and edits.
    public convenience init(corrected: String, edits: [ModelAnswer.Edit] = []) {
        let json = String(decoding: try! JSONEncoder().encode(ModelAnswer(corrected: corrected, edits: edits)), as: UTF8.self)
        self.init { _, _ in json }
    }

    public var callCount: Int { lock.withLock { calls.count } }

    public func complete(system: String, examples: [Prompt.Turn], user: String, jsonSchema: Data?,
                         params: GenParams) async throws -> String {
        lock.withLock { calls.append((system, user)) }
        try Task.checkCancellation()
        return try await responder(system, user)
    }
}
