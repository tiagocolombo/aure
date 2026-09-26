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
    /// Parses model output. Tolerates code fences, `<think>` blocks and text
    /// before/after the JSON object.
    public static func parse(_ raw: String) throws -> ModelAnswer {
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
    public struct Config: Sendable {
        /// Max share of original tokens that may change in `correct` mode.
        public var maxCorrectChangeRatio: Double = 0.35
        public init() {}
    }

    /// Returns the text to use as `corrected`, or throws `rejected`.
    public static func validate(original: String, answer: ModelAnswer, mode: CheckMode,
                                config: Config = Config()) throws -> String {
        var corrected = answer.corrected
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
        return edits.first { e in
            let f = e.from.lowercased(), t = e.to.lowercased()
            return (!o.isEmpty && (f.contains(o) || o.contains(f)) && !f.isEmpty)
                || (!r.isEmpty && (t.contains(r) || r.contains(t)) && !t.isEmpty)
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
        default: return "Suggested correction"
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
