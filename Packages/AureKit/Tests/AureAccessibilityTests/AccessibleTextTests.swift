import Foundation
import Testing
@testable import AureAccessibility

@Test func partialValueDoesNotBecomeAWholeDocumentSnapshot() {
    #expect(AccessibleText.read(value: "part", characterCount: 13) { _ in "full document" } == "full document")
    #expect(AccessibleText.read(value: "part", characterCount: 13) { _ in nil } == nil)
}

@Test func emptyValueDoesNotHideRangeText() {
    #expect(AccessibleText.read(value: "", characterCount: 5) { _ in "Hello" } == "Hello")
}

@Test func rejectsPartialRangeTextAndInvalidLengths() {
    #expect(AccessibleText.read(value: nil, characterCount: 10) { _ in "short" } == nil)
    for count: Int? in [nil, -1, 0, Int.max] {
        #expect(AccessibleText.read(value: nil, characterCount: count) { _ in
            Issue.record("Must not request unbounded/invalid ranges")
            return "bad"
        } == nil)
    }
}

@Test func ordinaryValueDoesNotRequireRangeAPI() {
    #expect(AccessibleText.read(value: "Email body", characterCount: nil) { _ in
        Issue.record("AXValue should be sufficient")
        return nil
    } == "Email body")
    #expect(AccessibleText.read(value: "", characterCount: 0) { _ in nil } == "")
}

@Test func readsRangeTextWhenValueIsMissing() {
    let text = "This 😀 are a test."
    let actual = AccessibleText.read(value: nil, characterCount: (text as NSString).length) { range in
        #expect(range == 0..<(text as NSString).length)
        return text
    }
    #expect(actual == text)
}
