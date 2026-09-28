import Foundation

/// The pure preflight used before either AX writes or a user-requested paste.
enum ReplacementSafety {
    static func expectedText(original: String, current: String?, range: Range<Int>,
                             replacement: String, hasFocus: Bool) -> String? {
        let ns = original as NSString
        guard hasFocus, current == original, range.lowerBound >= 0,
              range.upperBound <= ns.length else { return nil }
        // Foundation can normalize an index inside a surrogate pair to the
        // surrounding Character. Reject those offsets instead of widening an edit.
        for offset in [range.lowerBound, range.upperBound] where offset < ns.length {
            if (0xDC00...0xDFFF).contains(ns.character(at: offset)) { return nil }
        }
        return ns.replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: replacement)
    }

    enum WriteOutcome: Equatable { case applied, ignored, uncertain }

    /// Classifies the field text after an AX write the target app accepted.
    /// Chrome and Electron often report success but leave the field untouched;
    /// only that case is safe to retry with a paste.
    static func writeOutcome(original: String, expected: String, current: String?) -> WriteOutcome {
        if current == expected { return .applied }
        if current == original { return .ignored }
        return .uncertain
    }
}
