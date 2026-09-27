import Foundation

/// Word-level diff between an original and a corrected text.
///
/// Text is tokenized into words, whitespace runs and single punctuation marks,
/// then diffed with Myers' algorithm (via `CollectionDifference`). Adjacent
/// changes are merged into hunks whose ranges are UTF-16 offsets into the
/// original, so they can be applied to NSString / AX / DOM text directly.
public enum DiffEngine {
    public struct Hunk: Equatable, Sendable {
        /// UTF-16 range in the original text (empty for pure insertions).
        public var range: Range<Int>
        public var original: String
        public var replacement: String

        public init(range: Range<Int>, original: String, replacement: String) {
            self.range = range
            self.original = original
            self.replacement = replacement
        }
    }

    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: Kind?

        enum Kind { case word, space }

        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
            currentKind = nil
        }

        for ch in text {
            let kind: Kind?
            if ch.isWhitespace {
                kind = .space
            } else if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" || ch == "_" {
                kind = .word
            } else {
                kind = nil // punctuation / symbol / emoji: its own token
            }
            if let kind, kind == currentKind {
                current.append(ch)
            } else {
                flush()
                if let kind {
                    current.append(ch)
                    currentKind = kind
                } else {
                    tokens.append(String(ch))
                }
            }
        }
        flush()
        return tokens
    }

    public static func hunks(from original: String, to corrected: String) -> [Hunk] {
        let a = tokenize(original)
        let b = tokenize(corrected)
        if a == b { return [] }

        let diff = b.difference(from: a)
        var removed = Set<Int>()
        var inserted: [Int: String] = [:] // new-index -> token
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, element, _): inserted[offset] = element
            }
        }

        // UTF-16 start offset of every original token.
        var starts: [Int] = []
        var pos = 0
        for t in a {
            starts.append(pos)
            pos += t.utf16.count
        }
        let endOffset = pos

        // Walk both sequences together, grouping consecutive changes.
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let isRemoved = i < a.count && removed.contains(i)
            let isInserted = j < b.count && inserted[j] != nil
            if !isRemoved && !isInserted {
                i += 1; j += 1
                continue
            }
            let startI = i
            var orig = ""
            var repl = ""
            while (i < a.count && removed.contains(i)) || (j < b.count && inserted[j] != nil) {
                if i < a.count && removed.contains(i) { orig += a[i]; i += 1 }
                if j < b.count, let t = inserted[j] { repl += t; j += 1 }
            }
            let lo = startI < a.count ? starts[startI] : endOffset
            let hi = i < a.count ? starts[i] : endOffset
            hunks.append(Hunk(range: lo..<hi, original: orig, replacement: repl))
        }
        return mergeAcrossSingleSpaces(hunks, original: original)
    }

    /// "their going" -> "they're going" should read as one change, and so should
    /// "a apple" -> "an apple" but not unrelated edits far apart. Merge hunks
    /// separated only by one whitespace token.
    static func mergeAcrossSingleSpaces(_ hunks: [Hunk], original: String) -> [Hunk] {
        guard hunks.count > 1 else { return hunks }
        let ns = original as NSString
        var out: [Hunk] = [hunks[0]]
        for h in hunks.dropFirst() {
            var last = out[out.count - 1]
            let gap = last.range.upperBound..<h.range.lowerBound
            let gapText = gap.isEmpty ? "" : ns.substring(with: NSRange(location: gap.lowerBound, length: gap.count))
            let touchesWord = [last.original, last.replacement, h.original, h.replacement]
                .contains { $0.contains { $0.isLetter } }
            if gapText.count == 1, gapText.allSatisfy(\.isWhitespace), touchesWord {
                last.range = last.range.lowerBound..<h.range.upperBound
                last.original += gapText + h.original
                last.replacement += gapText + h.replacement
                out[out.count - 1] = last
            } else {
                out.append(h)
            }
        }
        return out
    }

    /// Apply hunks (non-overlapping, any order) to the original text.
    public static func apply(_ hunks: [Hunk], to original: String) -> String {
        let ns = NSMutableString(string: original)
        for h in hunks.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            ns.replaceCharacters(in: NSRange(location: h.range.lowerBound, length: h.range.count), with: h.replacement)
        }
        return ns as String
    }
}
