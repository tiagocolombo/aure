import Foundation
import Testing
@testable import AureAccessibility

@Test func replacementRequiresUnchangedFocusedTargetAndValidUTF16Range() {
    let original = "Hi 😀 friend"
    #expect(ReplacementSafety.expectedText(original: original, current: original, range: 3..<5,
                                           replacement: "dear", hasFocus: true) == "Hi dear friend")
    #expect(ReplacementSafety.expectedText(original: original, current: "changed", range: 3..<5,
                                           replacement: "dear", hasFocus: true) == nil)
    #expect(ReplacementSafety.expectedText(original: original, current: original, range: 3..<5,
                                           replacement: "dear", hasFocus: false) == nil)
    for range in [-1..<0, 0..<100, 4..<5] {
        #expect(ReplacementSafety.expectedText(original: original, current: original, range: range,
                                               replacement: "dear", hasFocus: true) == nil)
    }
}
