import AppKit
import AureCore
import Foundation

/// Prompt → model → parse → validate → diff → CheckResult.
public actor CorrectionService {
    private var provider: (any LLMProvider)?
    private var cache: [CacheKey: CheckResult] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit = 200
    private var inFlight: [CacheKey: Task<CheckResult, Error>] = [:]

    public var style: StyleContext = .empty
    public var toneDefinitions: [Tone: ToneDefinition] = [:]

    struct CacheKey: Hashable {
        var request: CheckRequest
        var styleHash: Int
    }

    public init(provider: (any LLMProvider)? = nil) {
        self.provider = provider
    }

    public func setProvider(_ p: (any LLMProvider)?) {
        provider = p
        clearCache()
    }

    public func setStyle(_ s: StyleContext) {
        style = s
        clearCache()
    }

    public func setToneDefinition(_ d: ToneDefinition) {
        toneDefinitions[d.tone] = d
        clearCache()
    }

    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    public var hasProvider: Bool { provider != nil }

    public func check(_ request: CheckRequest) async throws -> CheckResult {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return CheckResult(request: request, corrected: request.text, issues: [], latencyMs: 0)
        }
        let key = CacheKey(request: request, styleHash: style.hashValue ^ (toneDefinitions[request.tone]?.description.hashValue ?? 0))
        if let hit = cache[key] { return hit }
        if let running = inFlight[key] { return try await running.value }

        guard let provider else { throw AureError.modelNotLoaded }
        let prompt = PromptBuilder.build(request, toneDefinition: toneDefinitions[request.tone], style: style)
        let schema = try? JSONSerialization.data(withJSONObject: PromptBuilder.responseSchema)
        let dictionary = Set(style.dictionary.map { $0.lowercased() })

        let task = Task<CheckResult, Error> {
            let started = Date()
            let raw = try await provider.complete(system: prompt.system, user: prompt.user, jsonSchema: schema,
                                                  params: GenParams(temperature: prompt.temperature, maxTokens: prompt.maxTokens))
            try Task.checkCancellation()
            let answer = try ResponseParser.parse(raw)
            var corrected = try Validator.validate(original: request.text, answer: answer, mode: request.mode)
            corrected = Self.restoreDictionaryWords(original: request.text, corrected: corrected, dictionary: dictionary)
            if request.mode == .correct {
                corrected = IssueBuilder.filterNoise(original: request.text, corrected: corrected)
            }
            var issues = IssueBuilder.issues(original: request.text, corrected: corrected, edits: answer.edits)
            if request.mode == .correct {
                issues += await Self.spellingIssues(in: request.text, dialect: request.dialect,
                                                    dictionary: dictionary, excluding: issues)
                issues.sort { $0.range.lowerBound < $1.range.lowerBound }
                corrected = Self.applying(issues, to: request.text)
            }
            return CheckResult(request: request, corrected: corrected, issues: issues,
                               latencyMs: Int(Date().timeIntervalSince(started) * 1000))
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        store(key, result)
        return result
    }

    private func store(_ key: CacheKey, _ result: CheckResult) {
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    /// Text with the given (non-overlapping) issues applied.
    public static func applying(_ issues: [Issue], to original: String) -> String {
        DiffEngine.apply(issues.map { DiffEngine.Hunk(range: $0.range, original: $0.original, replacement: $0.replacement) },
                         to: original)
    }

    /// Words from the personal dictionary must never be "corrected".
    static func restoreDictionaryWords(original: String, corrected: String, dictionary: Set<String>) -> String {
        guard !dictionary.isEmpty else { return corrected }
        let hunks = DiffEngine.hunks(from: original, to: corrected).filter { h in
            !dictionary.contains(h.original.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return DiffEngine.apply(hunks, to: original)
    }

    /// NSSpellChecker pass that catches misspellings the model missed.
    @MainActor
    static func spellingIssues(in text: String, dialect: Dialect, dictionary: Set<String>,
                               excluding existing: [Issue]) -> [Issue] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var out: [Issue] = []
        var offset = 0
        while offset < ns.length {
            let r = checker.checkSpelling(of: text, startingAt: offset, language: dialect.spellCheckerLanguage,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard r.location != NSNotFound, r.length > 0 else { break }
            offset = r.location + r.length
            let word = ns.substring(with: r)
            let range = r.location..<(r.location + r.length)
            if dictionary.contains(word.lowercased()) { continue }
            if existing.contains(where: { $0.range.overlaps(range) || $0.range.lowerBound == range.lowerBound }) { continue }
            // Skip mentions, hashtags, URLs, code-ish tokens and ALLCAPS acronyms.
            let before = r.location > 0 ? ns.substring(with: NSRange(location: r.location - 1, length: 1)) : " "
            if "@#/`_.:".contains(before) || word == word.uppercased() { continue }
            guard let guess = checker.correction(forWordRange: r, in: text, language: dialect.spellCheckerLanguage,
                                                 inSpellDocumentWithTag: 0) else { continue }
            out.append(Issue(range: range, original: word, replacement: guess, category: .spelling,
                             explanation: "Possible misspelling"))
        }
        return out
    }
}
