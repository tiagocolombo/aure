import AureCore
import Foundation
import Testing
@testable import AureUI

private func issue(_ range: Range<Int>, _ original: String, _ replacement: String) -> AureCore.Issue {
    AureCore.Issue(range: range, original: original, replacement: replacement, category: .grammar, explanation: "test")
}

private func review(_ text: String, mode: CheckMode = .correct, issues: [AureCore.Issue]) -> PadReview {
    PadReview(result: CheckResult(request: CheckRequest(text: text, tone: .formal, mode: mode),
                                  corrected: text, issues: issues, latencyMs: 0))
}

@Test func textEditFindsTheChangedRange() {
    #expect(TextEdit(from: "She go home", to: "She goes home") == TextEdit(range: 6..<6, replacementLength: 2))
    #expect(TextEdit(from: "She go home", to: "She home") == TextEdit(range: 4..<7, replacementLength: 0))
    #expect(TextEdit(from: "aa", to: "aaa") == TextEdit(range: 2..<2, replacementLength: 1))
    #expect(TextEdit(from: "same", to: "same") == TextEdit(range: 4..<4, replacementLength: 0))
}

@Test func typingMovesLaterUnderlinesAndDropsTouchedOnes() {
    // "Their going too the park."
    let their = issue(0..<5, "Their", "They're")
    let too = issue(12..<15, "too", "to")
    var r = review("Their going too the park.", issues: [their, too])

    r.textChanged(to: "Their going too the big park.")  // after both
    #expect(r.result.issues.map(\.range) == [0..<5, 12..<15])

    r.textChanged(to: "Their really going too the big park.")  // between: only "too" moves
    #expect(r.result.issues.map(\.range) == [0..<5, 19..<22])

    r.textChanged(to: "Theirs really going too the big park.")  // touches "Their"
    #expect(r.result.issues.map(\.id) == [too.id])
    #expect(r.result.issues.first?.range == 20..<23)
    #expect(r.text == "Theirs really going too the big park.")
}

@Test func applyingAFixShiftsTheRestAndKeepsNeighbours() {
    // "teh," → "the": the comma fix right next to it survives.
    let teh = issue(0..<3, "teh", "the")
    let comma = issue(3..<4, ",", "")
    var adjacent = review("teh, ok", issues: [teh, comma])
    #expect(adjacent.apply(teh.id) == "the, ok")
    #expect(adjacent.result.issues.map(\.range) == [3..<4])

    let i = issue(0..<1, "i", "I")
    let has = issue(2..<5, "has", "have")
    let a = issue(6..<7, "a", "an")
    var r = review("i has a apple", issues: [i, has, a])

    let new = r.apply(has.id)
    #expect(new == "i have a apple")
    #expect(r.text == new)
    #expect(r.result.issues.map(\.id) == [i.id, a.id])
    #expect(r.result.issues.map(\.range) == [0..<1, 7..<8])
    #expect(r.apply(a.id) == "i have an apple")
    #expect(r.apply(i.id) == "I have an apple")
    #expect(r.result.issues.isEmpty)
}

@Test func colorsFollowTheKindOfChange() {
    let fix = issue(4..<6, "go", "goes")
    #expect(review("She go home", issues: [fix]).annotations.map(\.kind) == [.issue])
    #expect(review("She go home", mode: .rewrite, issues: [fix]).annotations.map(\.kind) == [.suggestion])

    var r = review("She go home", issues: [fix])
    r.dismiss(fix.id)
    #expect(r.annotations.isEmpty)
}

@Test func writingSuggestionIsAskedOnceWhenNoFixesRemain() throws {
    let fix = issue(4..<6, "go", "goes")
    var r = review("She go home now.", issues: [fix])
    #expect(!r.wantsWritingSuggestion)

    r.apply(fix.id)
    #expect(r.wantsWritingSuggestion)
    r.writingRequested = true
    let suggestion = try #require(WritingSuggestion(original: "She goes home now.", replacement: "She heads home now.",
                                                    tone: .formal))
    r.setWriting(suggestion)
    #expect(r.annotations.map(\.kind) == [.suggestion])
    let yellow = try #require(r.visibleWriting.first)
    #expect(yellow.range == 4..<8)
    #expect(yellow.replacement == "heads")
    #expect(yellow.explanation == "Formal alternative")

    r.apply(yellow.id)
    #expect(r.text == "She heads home now.")
    #expect(!r.wantsWritingSuggestion)
}

@Test func dismissingAFixBlocksTheWritingSuggestion() {
    let fix = issue(4..<6, "go", "goes")
    var r = review("She go home", issues: [fix])
    r.dismiss(fix.id)
    #expect(!r.wantsWritingSuggestion)
    #expect(!review("She goes home", mode: .rewrite, issues: []).wantsWritingSuggestion)
}

@Test func staleWritingSuggestionIsIgnored() throws {
    var r = review("She goes home.", issues: [])
    r.textChanged(to: "She goes home today.")
    r.setWriting(try #require(WritingSuggestion(original: "She goes home.", replacement: "She heads home.",
                                                tone: .formal)))
    #expect(r.writing.isEmpty)
}

@Test func insertionsUnderlineTheNeighbouringWord() {
    let text = "Hello how are you"
    #expect(issue(5..<5, "", ",").underlineRange(in: text) == 0..<5)
    #expect(issue(6..<6, "", "oh ").underlineRange(in: text) == 0..<5)
    #expect(issue(0..<0, "", "Oh, ").underlineRange(in: text) == 0..<5)
    #expect(issue(6..<9, "how", "who").underlineRange(in: text) == 6..<9)
    #expect(issue(0..<0, "", "x").underlineRange(in: "   ") == nil)
    #expect(issue(10..<12, "x", "y").underlineRange(in: "short") == nil)
}
