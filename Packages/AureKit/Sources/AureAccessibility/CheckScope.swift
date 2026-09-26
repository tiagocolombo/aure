import Foundation

/// Picks the part of a field to check: the paragraph around the caret,
/// capped in length, and decides whether it is worth checking at all.
public enum CheckScope {
    public struct Slice: Equatable, Sendable {
        /// UTF-16 range of the slice in the full text.
        public var range: Range<Int>
        public var text: String
    }

    public static let maxLength = 2000
    public static let minCharacters = 12
    public static let minWords = 3

    public static func isWorthChecking(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= minCharacters else { return false }
        let words = t.split { $0.isWhitespace }.filter { $0.contains { $0.isLetter } }
        return words.count >= minWords
    }

    /// The paragraph (text between blank lines) containing `caret`, or the
    /// whole text if it is short. Never exceeds `maxLength`.
    public static func slice(of text: String, caret: Int?) -> Slice {
        let ns = text as NSString
        let len = ns.length
        if len <= maxLength { return Slice(range: 0..<len, text: text) }
        let c = min(max(caret ?? len, 0), len)
        let before = ns.range(of: "\n\n", options: .backwards, range: NSRange(location: 0, length: c))
        var start = before.location == NSNotFound ? 0 : before.location + before.length
        let after = ns.range(of: "\n\n", options: [], range: NSRange(location: c, length: len - c))
        var end = after.location == NSNotFound ? len : after.location
        if end - start > maxLength {
            start = max(start, c - maxLength / 2)
            end = min(end, start + maxLength)
        }
        return Slice(range: start..<end, text: ns.substring(with: NSRange(location: start, length: end - start)))
    }
}
