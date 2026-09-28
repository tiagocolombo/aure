import Foundation

/// Raw model answer, before validation.
public struct ModelAnswer: Codable, Equatable, Sendable {
    public struct Edit: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var category: String?
        public var why: String?

        public init(from: String, to: String, category: String? = nil, why: String? = nil) {
            self.from = from
            self.to = to
            self.category = category
            self.why = why
        }
    }

    public var corrected: String
    public var edits: [Edit]

    public init(corrected: String, edits: [Edit]) {
        self.corrected = corrected
        self.edits = edits
    }
}

public enum ResponseParser {
    /// Parses a plain-text answer (the corrected text only). Removes thinking
    /// blocks, code fences, "Corrected:" style labels and wrapping quotes the
    /// original did not have. Falls back to JSON if the model answered in JSON.
    public static func parse(_ raw: String, original: String) throws -> ModelAnswer {
        var s = raw
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{"), let json = try? parseJSON(s) { return json }
        if s.hasPrefix("```") {
            s = s.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let r = s.range(of: "```", options: .backwards) { s = String(s[..<r.lowerBound]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["Corrected text:", "Corrected:", "Correction:", "Text:", "Output:"]
        where s.lowercased().hasPrefix(label.lowercased()) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")]
        where s.hasPrefix(open) && s.hasSuffix(close) && s.count > 1 && !(o.hasPrefix(open) && o.hasSuffix(close)) {
            s = String(s.dropFirst().dropLast())
        }
        if s.isEmpty { throw AureError.invalidModelOutput("empty answer") }
        return ModelAnswer(corrected: s, edits: [])
    }

    /// Parses a JSON answer {"corrected": ..., "edits": [...]}. Tolerates code
    /// fences, `<think>` blocks and text before/after the JSON object.
    public static func parseJSON(_ raw: String) throws -> ModelAnswer {
        var s = raw
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }
        guard let start = s.firstIndex(of: "{") else {
            throw AureError.invalidModelOutput("no JSON object")
        }
        // Find the matching closing brace, respecting strings.
        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
            }
            i = s.index(after: i)
        }
        guard let end else { throw AureError.invalidModelOutput("unterminated JSON") }
        let json = String(s[start...end])
        do {
            return try JSONDecoder().decode(ModelAnswer.self, from: Data(json.utf8))
        } catch {
            // `edits` may be missing in some small-model outputs; accept corrected only.
            struct OnlyCorrected: Decodable { var corrected: String }
            if let o = try? JSONDecoder().decode(OnlyCorrected.self, from: Data(json.utf8)) {
                return ModelAnswer(corrected: o.corrected, edits: [])
            }
            throw AureError.invalidModelOutput("bad JSON")
        }
    }
}

public enum Validator {
    /// Drops invisible characters the original does not contain: zero-width
    /// spaces and joiners, bidirectional overrides (which can make text display in
    /// a different order than it reads), tag characters and control characters.
    /// A review diff cannot show them, so the user could not approve them.
    public static func removingHiddenCharacters(_ text: String, keepingThoseIn original: String) -> String {
        let allowed = Set(original.unicodeScalars)
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let hidden: Bool
            switch scalar.properties.generalCategory {
            case .format: hidden = true
            case .control: hidden = !["\n", "\r", "\t"].contains(scalar)
            default: hidden = false
            }
            if !hidden || allowed.contains(scalar) { out.append(scalar) }
        }
        return String(out)
    }


    public struct Config: Sendable {
        /// Max share of original tokens that may change in `correct` mode.
        public var maxCorrectChangeRatio: Double = 0.35
        public init() {}
    }

    /// Returns the text to use as `corrected`, or throws `rejected`.
    public static func validate(original: String, answer: ModelAnswer, mode: CheckMode,
                                config: Config = Config()) throws -> String {
        var corrected = removingHiddenCharacters(answer.corrected, keepingThoseIn: original)
        // Models often trim; restore the original's leading/trailing whitespace.
        let lead = original.prefix { $0.isWhitespace }
        let trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        corrected = String(lead) + corrected.trimmingCharacters(in: .whitespacesAndNewlines) + trail

        if corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AureError.rejected("empty answer")
        }
        if corrected == original { return corrected }

        for token in protectedTokens(in: original) where !corrected.contains(token) {
            throw AureError.rejected("changed protected text \(token)")
        }

        if mode == .correct {
            let ratio = changeRatio(original, corrected)
            // Short texts: one or two fixes are always a legitimate correction.
            let wordCount = DiffEngine.tokenize(original).filter { $0.first?.isLetter == true }.count
            let changedWords = ratio * Double(max(wordCount, 1))
            if ratio > config.maxCorrectChangeRatio && changedWords > 2 {
                throw AureError.rejected("too many changes for a correction (\(Int(ratio * 100))%)")
            }
        } else {
            // A rewrite should not balloon or collapse.
            let a = Double(original.count), b = Double(corrected.count)
            if a > 20 && (b > a * 2.5 || b < a * 0.3) {
                throw AureError.rejected("rewrite length changed too much")
            }
        }
        return corrected
    }

    /// URLs, emails, @mentions, #channels, `code` spans and emoji must survive.
    public static func protectedTokens(in text: String) -> [String] {
        var out: [String] = []
        let patterns = [
            #"https?://\S+"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #"(?<![A-Za-z0-9])[@#][A-Za-z0-9._-]+"#,
            #"`[^`]+`"#,
        ]
        let ns = text as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var t = ns.substring(with: m.range)
                // Trailing sentence punctuation is not part of a URL/mention.
                while let last = t.last, ".,;:!?)".contains(last) { t.removeLast() }
                if !t.isEmpty { out.append(t) }
            }
        }
        for ch in text where ch.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
            out.append(String(ch))
        }
        return out
    }

    /// Share of non-whitespace original tokens touched by the diff.
    public static func changeRatio(_ a: String, _ b: String) -> Double {
        let tokens = DiffEngine.tokenize(a).filter { !$0.allSatisfy(\.isWhitespace) }
        guard !tokens.isEmpty else { return 0 }
        let hunks = DiffEngine.hunks(from: a, to: b)
        let changed = hunks.reduce(0) { acc, h in
            acc + max(1, DiffEngine.tokenize(h.original).filter { !$0.allSatisfy(\.isWhitespace) }.count)
        }
        return min(1, Double(changed) / Double(tokens.count))
    }
}

public enum IssueBuilder {
    /// Drops edits small models make that are almost never real corrections:
    /// lowercasing a word (e.g. "I'll" → "i'll") and deleting only final
    /// punctuation. Returns the corrected text with those hunks reverted.
    public static func filterNoise(original: String, corrected: String) -> String {
        let hunks = DiffEngine.hunks(from: original, to: corrected).compactMap { h -> DiffEngine.Hunk? in
            let o = h.original, r = h.replacement
            if !o.isEmpty, o.lowercased() == r.lowercased(), r == r.lowercased(), o != r { return nil }
            // "Their" -> "they're" at the start of a sentence: keep the capital.
            // ("you and I" -> "you and me" must stay lowercase.)
            let before = (original as NSString).substring(to: h.range.lowerBound)
                .trimmingCharacters(in: .whitespaces)
            let sentenceStart = before.isEmpty || ".!?\n".contains(before.last!)
            if sentenceStart, let of = o.first, let rf = r.first, of.isUppercase, rf.isLowercase,
               o.lowercased() != r.lowercased() {
                var h = h
                h.replacement = rf.uppercased() + r.dropFirst()
                return h
            }
            if r.isEmpty, !o.isEmpty, o.allSatisfy({ ".!?".contains($0) }) { return nil }
            // "tomorow." -> "tomorrow": keep the sentence-ending punctuation.
            if let last = o.last, ".!?".contains(last), !r.isEmpty, r.last != last,
               !(r.last.map { ".!?".contains($0) } ?? false) {
                var h = h
                h.replacement.append(last)
                return h.original == h.replacement ? nil : h
            }
            return h
        }
        return DiffEngine.apply(hunks, to: original)
    }

    /// Turns the (validated) corrected text into issues with local offsets,
    /// labelling each diff hunk with the model's category/reason when they match.
    public static func issues(original: String, corrected: String, edits: [ModelAnswer.Edit]) -> [Issue] {
        DiffEngine.hunks(from: original, to: corrected).map { h in
            let edit = bestEdit(for: h, in: edits)
            let category = edit.flatMap { $0.category.flatMap(Issue.Category.init(rawValue:)) }
                ?? guessCategory(h)
            let why = edit?.why?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Issue(range: h.range, original: h.original, replacement: h.replacement,
                         category: category,
                         explanation: (why?.isEmpty == false ? why! : defaultExplanation(category, h)))
        }
    }

    static func bestEdit(for h: Hunk, in edits: [ModelAnswer.Edit]) -> ModelAnswer.Edit? {
        let o = h.original.trimmingCharacters(in: .whitespaces).lowercased()
        let r = h.replacement.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = edits.first(where: { $0.from.lowercased() == o && $0.to.lowercased() == r }) { return exact }
        // Otherwise the edit must mention this hunk's original words (whole
        // words), and its replacement must contain ours, or vice versa.
        func words(_ s: String) -> Set<String> {
            Set(DiffEngine.tokenize(s).filter { $0.first?.isLetter == true }.map { $0.lowercased() })
        }
        let ow = words(o), rw = words(r)
        return edits.first { e in
            let fw = words(e.from), tw = words(e.to)
            let fromMatches = !ow.isEmpty && ow.isSubset(of: fw)
            let toMatches = !rw.isEmpty && (rw.isSubset(of: tw) || tw.isSubset(of: rw)) && !tw.isEmpty
            return fromMatches && (toMatches || rw.isEmpty)
        }
    }

    typealias Hunk = DiffEngine.Hunk

    static func guessCategory(_ h: Hunk) -> Issue.Category {
        let both = (h.original + h.replacement).trimmingCharacters(in: .whitespaces)
        if !both.isEmpty && both.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return .punctuation }
        let o = h.original.lowercased(), r = h.replacement.lowercased()
        if o == r { return .punctuation } // capitalization only
        if !o.contains(" ") && !r.contains(" ") && editDistance(o, r) <= 2 { return .spelling }
        return .grammar
    }

    static func defaultExplanation(_ c: Issue.Category, _ h: Hunk) -> String {
        if h.original.isEmpty { return "Add \"\(h.replacement.trimmingCharacters(in: .whitespaces))\"" }
        if h.replacement.isEmpty { return "Remove \"\(h.original.trimmingCharacters(in: .whitespaces))\"" }
        switch c {
        case .spelling: return "Spelling"
        case .punctuation: return "Punctuation or capitalization"
        case .tone: return "Better fits the selected tone"
        default: return "Grammar fix"
        }
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
