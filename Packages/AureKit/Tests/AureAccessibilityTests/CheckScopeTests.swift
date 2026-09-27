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

    @Test func longEmailIsCheckedWhole() {
        // ~4,500 characters: a long email is checked in full, not just the caret paragraph.
        let p = String(repeating: "This paragraph has some words in it. ", count: 30)
        let text = [p, p, p, p].joined(separator: "\n\n")
        #expect((text as NSString).length > 4000)
        let s = CheckScope.slice(of: text, caret: 10)
        #expect(s.range == 0..<(text as NSString).length)
    }

    @Test func documentUsesCaretParagraph() {
        let p1 = String(repeating: "First paragraph words. ", count: 300)
        let p2 = "Second paragraph has a eror."
        let p3 = String(repeating: "Third paragraph words. ", count: 300)
        let text = p1 + "\n\n" + p2 + "\n\n" + p3
        #expect((text as NSString).length > CheckScope.maxLength)
        let caret = (p1 as NSString).length + 2 + 5
        let s = CheckScope.slice(of: text, caret: caret)
        #expect(s.text == p2)
        #expect((text as NSString).substring(with: NSRange(location: s.range.lowerBound, length: s.range.count)) == p2)
    }

    @Test func hugeParagraphIsCapped() {
        let text = String(repeating: "word ", count: 4000)
        let s = CheckScope.slice(of: text, caret: 15000)
        #expect(s.range.count <= CheckScope.maxLength)
        #expect(s.range.contains(15000) || s.range.upperBound == 15000)
    }
}
