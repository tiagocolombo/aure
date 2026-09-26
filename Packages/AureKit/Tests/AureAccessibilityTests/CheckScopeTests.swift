import Foundation
import Testing
@testable import AureAccessibility

@Suite struct CheckScopeTests {
    @Test func worthChecking() {
        #expect(!CheckScope.isWorthChecking("ok"))
        #expect(!CheckScope.isWorthChecking("       "))
        #expect(!CheckScope.isWorthChecking("https://x.com/abc"))
        #expect(CheckScope.isWorthChecking("their going to the store"))
    }

    @Test func shortTextIsWholeSlice() {
        let s = CheckScope.slice(of: "Hello there, how are you?", caret: 3)
        #expect(s.range == 0..<25)
    }

    @Test func longTextUsesCaretParagraph() {
        let p1 = String(repeating: "First paragraph words. ", count: 60)
        let p2 = "Second paragraph has a eror."
        let p3 = String(repeating: "Third paragraph words. ", count: 60)
        let text = p1 + "\n\n" + p2 + "\n\n" + p3
        let caret = (p1 as NSString).length + 2 + 5
        let s = CheckScope.slice(of: text, caret: caret)
        #expect(s.text == p2)
        #expect((text as NSString).substring(with: NSRange(location: s.range.lowerBound, length: s.range.count)) == p2)
    }

    @Test func hugeParagraphIsCapped() {
        let text = String(repeating: "word ", count: 2000)
        let s = CheckScope.slice(of: text, caret: 5000)
        #expect(s.range.count <= CheckScope.maxLength)
        #expect(s.range.contains(5000) || s.range.upperBound == 5000)
    }
}
