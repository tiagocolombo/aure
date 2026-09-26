import Testing
@testable import AureCore

@Suite struct DiffEngineTests {
    @Test func noChangeProducesNoHunks() {
        #expect(DiffEngine.hunks(from: "All good here.", to: "All good here.").isEmpty)
    }

    @Test func singleWordReplacement() {
        let h = DiffEngine.hunks(from: "I goed home.", to: "I went home.")
        #expect(h.count == 1)
        #expect(h[0].original == "goed")
        #expect(h[0].replacement == "went")
        #expect(h[0].range == 2..<6)
    }

    @Test func adjacentWordsMergeIntoOneHunk() {
        let h = DiffEngine.hunks(from: "their going to the store", to: "they're going to the store")
        #expect(h.count == 1)
        #expect(h[0].original == "their")
        #expect(h[0].replacement == "they're")
    }

    @Test func separateEditsStaySeparate() {
        let s = "their going to the store tomorow"
        let c = "they're going to the store tomorrow"
        let h = DiffEngine.hunks(from: s, to: c)
        #expect(h.map(\.original) == ["their", "tomorow"])
        #expect(DiffEngine.apply(h, to: s) == c)
    }

    @Test func punctuationInsertion() {
        let s = "Hi John how are you"
        let c = "Hi John, how are you?"
        let h = DiffEngine.hunks(from: s, to: c)
        #expect(h.count == 2)
        #expect(h[0].original.isEmpty && h[0].replacement == ",")
        #expect(DiffEngine.apply(h, to: s) == c)
    }

    @Test func emojiAndUTF16Offsets() {
        let s = "Great job 🎉 teh team"
        let c = "Great job 🎉 the team"
        let h = DiffEngine.hunks(from: s, to: c)
        #expect(h.count == 1)
        // 🎉 is 2 UTF-16 units: "Great job " (10) + 2 + " " (1) = 13
        #expect(h[0].range == 13..<16)
        #expect(DiffEngine.apply(h, to: s) == c)
    }

    @Test func multilineIsPreserved() {
        let s = "Hi,\n\nI has a question.\nThanks"
        let c = "Hi,\n\nI have a question.\nThanks"
        let h = DiffEngine.hunks(from: s, to: c)
        #expect(h.count == 1)
        #expect(DiffEngine.apply(h, to: s) == c)
    }

    @Test func applyRoundTripsOnManyEdits() {
        let s = "me and him goes to school everyday , its fun"
        let c = "He and I go to school every day; it's fun."
        #expect(DiffEngine.apply(DiffEngine.hunks(from: s, to: c), to: s) == c)
    }

    @Test func tokenizerKeepsContractions() {
        #expect(DiffEngine.tokenize("don't stop") == ["don't", " ", "stop"])
    }
}
