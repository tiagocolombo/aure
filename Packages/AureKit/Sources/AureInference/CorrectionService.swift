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
    public var promptStyle: PromptStyle = .aure
    /// Edits the model was less sure about than this are not shown (correct mode).
    public var minConfidence: Double = 0

    public func setPromptStyle(_ p: PromptStyle) {
        promptStyle = p
        clearCache()
    }

    public func setMinConfidence(_ c: Double) {
        minConfidence = c
        clearCache()
    }

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

    /// Longest piece sent to the model in one call (see `TextSegmenter`).
    public var maxSegmentCharacters = TextSegmenter.defaultMaxCharacters
    /// How many pieces of a long text are sent to the model at the same time.
    /// Should match the server's parallel slots (`LlamaServerProcess.Config.parallel`).
    public var maxParallel = 1

    public func setMaxParallel(_ n: Int) {
        maxParallel = max(1, n)
    }

    public func check(_ request: CheckRequest) async throws -> CheckResult {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return CheckResult(request: request, corrected: request.text, issues: [], latencyMs: 0)
        }
        guard request.mode == .correct else { return try await checkOne(request) }
        let ns = request.text as NSString
        let segments = TextSegmenter.segments(of: request.text, maxCharacters: maxSegmentCharacters)
        // Short text (no piece worth splitting out) or one piece covering it all: check as is.
        if segments.isEmpty || (segments.count == 1
            && ns.substring(with: NSRange(location: segments[0].lowerBound, length: segments[0].count)) == trimmed) {
            return try await checkOne(request)
        }
        return try await checkSegmented(request, segments: segments)
    }

    private enum PieceOutcome: Sendable {
        case issues([Issue])
        case failed(String)
    }

    /// Long text: check the pieces (up to `maxParallel` at a time; each is
    /// cached, so editing one paragraph only re-checks that paragraph), then merge.
    private func checkSegmented(_ request: CheckRequest, segments: [Range<Int>]) async throws -> CheckResult {
        let started = Date()
        let ns = request.text as NSString
        let subs: [(Range<Int>, CheckRequest)] = segments.map { r in
            var sub = request
            sub.text = ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
            return (r, sub)
        }
        let limit = max(1, maxParallel)

        let outcomes: [PieceOutcome] = try await withThrowingTaskGroup(of: (Int, PieceOutcome).self) { group in
            var results = [PieceOutcome](repeating: .issues([]), count: subs.count)
            var next = 0
            func add() {
                let i = next
                let (r, sub) = subs[i]
                next += 1
                group.addTask {
                    do {
                        let part = try await self.checkOne(sub)
                        return (i, .issues(part.issues.map { issue in
                            var issue = issue
                            issue.range = (issue.range.lowerBound + r.lowerBound)..<(issue.range.upperBound + r.lowerBound)
                            return issue
                        }))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch AureError.cancelled {
                        throw AureError.cancelled
                    } catch {
                        // One bad piece (e.g. rejected answer) should not hide the others.
                        return (i, .failed(error.localizedDescription))
                    }
                }
            }
            while next < min(limit, subs.count) { add() }
            while let (i, outcome) = try await group.next() {
                results[i] = outcome
                if next < subs.count { add() }
            }
            return results
        }

        var issues: [Issue] = []
        var failures: [String] = []
        for o in outcomes {
            switch o {
            case .issues(let list): issues += list
            case .failed(let why): failures.append(why)
            }
        }
        if failures.count == segments.count { throw AureError.rejected(failures[0]) }
        // Spelling in lines too short to send to the model ("Thansk,").
        let dictionary = Set(style.dictionary.map { $0.lowercased() })
        issues += await Self.spellingIssues(in: request.text, dialect: request.dialect,
                                            dictionary: dictionary, excluding: issues)
        issues.sort { $0.range.lowerBound < $1.range.lowerBound }
        return CheckResult(request: request, corrected: Self.applying(issues, to: request.text), issues: issues,
                           latencyMs: Int(Date().timeIntervalSince(started) * 1000))
    }

    private func checkOne(_ request: CheckRequest) async throws -> CheckResult {
        let key = CacheKey(request: request,
                           styleHash: style.hashValue ^ (toneDefinitions[request.tone]?.description.hashValue ?? 0)
                               ^ promptStyle.hashValue ^ minConfidence.hashValue)
        if let hit = cache[key] { return hit }
        if let running = inFlight[key] { return try await running.value }

        guard let provider else { throw AureError.modelNotLoaded }
        let prompt = PromptBuilder.build(request, toneDefinition: toneDefinitions[request.tone], style: style,
                                         promptStyle: promptStyle)
        let minConfidence = self.minConfidence
        let dictionary = Set(style.dictionary.map { $0.lowercased() })

        let task = Task<CheckResult, Error> {
            let started = Date()
            let wantConfidence = request.mode == .correct
            let completion = try await provider.generate(
                system: prompt.system, examples: prompt.examples, user: prompt.user, jsonSchema: nil,
                params: GenParams(temperature: prompt.temperature, maxTokens: prompt.maxTokens,
                                  topLogprobs: wantConfidence ? 5 : 0))
            try Task.checkCancellation()
            let answer = try ResponseParser.parse(completion.text, original: request.text)
            let scored = wantConfidence
                ? EditConfidence.score(original: request.text, output: answer.corrected, tokens: completion.tokens)
                : nil
            var corrected = try Validator.validate(original: request.text, answer: answer, mode: request.mode)
            corrected = Self.restoreDictionaryWords(original: request.text, corrected: corrected, dictionary: dictionary)
            if request.mode == .correct {
                corrected = IssueBuilder.filterNoise(original: request.text, corrected: corrected)
            }
            var issues = IssueBuilder.issues(original: request.text, corrected: corrected, edits: answer.edits)
            issues = await Self.relabel(issues, dialect: request.dialect)
            if let scored {
                issues = EditConfidence.apply(scored, to: issues)
            }
            if request.mode == .correct {
                issues = issues.filter { $0.confidence >= minConfidence }
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

    /// A "spelling" guess on a word the system dictionary knows (e.g. "Your"
    /// → "You're") is really a wrong word for the context.
    @MainActor
    static func relabel(_ issues: [Issue], dialect: Dialect) -> [Issue] {
        let checker = NSSpellChecker.shared
        return issues.map { issue in
            guard issue.category == .spelling, issue.explanation == "Spelling" else { return issue }
            let word = issue.original.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !word.contains(" ") else { return issue }
            let miss = checker.checkSpelling(of: word, startingAt: 0, language: dialect.spellCheckerLanguage,
                                             wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard miss.location == NSNotFound else { return issue } // really misspelled
            var i = issue
            i.category = .wordChoice
            i.explanation = "\"\(word)\" is a real word, but not the right one here"
            return i
        }
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
