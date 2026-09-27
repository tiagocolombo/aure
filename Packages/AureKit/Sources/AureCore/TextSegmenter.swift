import Foundation
import NaturalLanguage

/// Splits long text (a whole email) into pieces the model can handle well.
///
/// Small models correct single sentences and short paragraphs reliably, but
/// with a whole email they often copy the text back unchanged (Qwen3 4B fixed
/// 0 of 6 errors in a 700-character email). Each piece is sent to the model
/// on its own; this is only about text layout, never about grammar.
///
/// Rules: every line break ends a piece (paragraphs, list items, greeting
/// and sign-off lines); lines longer than `maxCharacters` are split between
/// sentences. Pieces with fewer than `minWords` words ("Hi Sarah,", "Tiago")
/// are skipped.
public enum TextSegmenter {
    public static let defaultMaxCharacters = 400
    public static let minWords = 3

    /// UTF-16 ranges of the pieces to check, in order.
    public static func segments(of text: String, maxCharacters: Int = defaultMaxCharacters) -> [Range<Int>] {
        let ns = text as NSString
        var out: [Range<Int>] = []
        var lineStart = 0
        while lineStart <= ns.length {
            let nl = ns.range(of: "\n", options: [], range: NSRange(location: lineStart, length: ns.length - lineStart))
            let lineEnd = nl.location == NSNotFound ? ns.length : nl.location
            if let r = trimmed(lineStart..<lineEnd, in: ns) {
                out += split(r, in: text, ns: ns, maxCharacters: maxCharacters)
            }
            if nl.location == NSNotFound { break }
            lineStart = lineEnd + 1
        }
        return out.filter { worthChecking(ns.substring(with: NSRange(location: $0.lowerBound, length: $0.count))) }
    }

    static func worthChecking(_ s: String) -> Bool {
        s.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }.count >= minWords
    }

    static func trimmed(_ r: Range<Int>, in ns: NSString) -> Range<Int>? {
        var a = r.lowerBound, b = r.upperBound
        func ws(_ i: Int) -> Bool {
            guard let u = UnicodeScalar(ns.character(at: i)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(u)
        }
        while a < b, ws(a) { a += 1 }
        while b > a, ws(b - 1) { b -= 1 }
        return a < b ? a..<b : nil
    }

    /// Splits one line at sentence boundaries into groups of at most `maxCharacters`
    /// (a single longer sentence stays whole).
    static func split(_ r: Range<Int>, in text: String, ns: NSString, maxCharacters: Int) -> [Range<Int>] {
        guard maxCharacters > 0, r.count > maxCharacters else { return [r] }
        let line = ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = line
        var sentences: [Range<Int>] = []
        tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
            let ns = NSRange(range, in: line)
            sentences.append((r.lowerBound + ns.location)..<(r.lowerBound + ns.location + ns.length))
            return true
        }
        guard sentences.count > 1 else { return [r] }

        var out: [Range<Int>] = []
        var cur: Range<Int>?
        for s in sentences {
            if let c = cur, s.upperBound - c.lowerBound <= maxCharacters {
                cur = c.lowerBound..<s.upperBound
            } else {
                if let c = cur { out.append(c) }
                cur = s
            }
        }
        if let c = cur { out.append(c) }
        return out.compactMap { trimmed($0, in: ns) }
    }
}
