import Foundation

/// A complete, zero-based AX text snapshot. Never interpret selected text or a
/// truncated accessibility window as the whole document: replacement offsets
/// would then be unsafe. This fallback is capability-based, not Docs detection.
enum AccessibleText {
    static let maximumRangeRead = 100_000

    static func read(value: String?, characterCount: Int?,
                     stringForRange: (Range<Int>) -> String?) -> String? {
        if let value, characterCount == nil || characterCount == (value as NSString).length { return value }
        guard let count = characterCount, count > 0, count <= maximumRangeRead,
              let text = stringForRange(0..<count), (text as NSString).length == count else { return nil }
        return text
    }
}
