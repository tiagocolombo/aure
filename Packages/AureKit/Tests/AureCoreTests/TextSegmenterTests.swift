import Foundation
import Testing
@testable import AureCore

@Suite struct TextSegmenterTests {
    func pieces(_ text: String, max: Int = TextSegmenter.defaultMaxCharacters) -> [String] {
        let ns = text as NSString
        return TextSegmenter.segments(of: text, maxCharacters: max).map {
            ns.substring(with: NSRange(location: $0.lowerBound, length: $0.count))
        }
    }

    @Test func singleSentenceIsOnePiece() {
        #expect(pieces("I look forward to hear from you.") == ["I look forward to hear from you."])
    }

    @Test func emailSplitsIntoParagraphsAndSkipsShortLines() {
        let email = "Hi Sarah,\n\nThe report are ready. Please review it.\n\nCould you call me on Thursday?\n\nThanks,\nTiago"
        #expect(pieces(email) == ["The report are ready. Please review it.", "Could you call me on Thursday?"])
    }

    @Test func listItemsArePiecesOfTheirOwn() {
        let text = "Recap:\n- @joao is still blocked on the keys.\n- The new flow is live on staging."
        #expect(pieces(text) == ["- @joao is still blocked on the keys.", "- The new flow is live on staging."])
    }

    @Test func longParagraphSplitsBetweenSentences() {
        let s1 = "The first sentence is about the migration project and its timeline."
        let s2 = "The second sentence explains who owns the monitoring dashboards."
        let s3 = "The third sentence asks for a call on Thursday afternoon."
        let out = pieces("\(s1) \(s2) \(s3)", max: 140)
        #expect(out == ["\(s1) \(s2)", s3])
    }

    @Test func rangesPointIntoTheOriginalText() {
        let text = "Hi,\n\n  Their going to be late.  \n\nBye"
        let r = TextSegmenter.segments(of: text)
        #expect(r.count == 1)
        #expect((text as NSString).substring(with: NSRange(location: r[0].lowerBound, length: r[0].count))
                == "Their going to be late.")
    }

    @Test func emojiBeforeAPieceKeepsUTF16Offsets() {
        let text = "🎉🎉 done!\nYour going to love the new search page."
        let r = TextSegmenter.segments(of: text)
        #expect(r.count == 1)
        #expect((text as NSString).substring(with: NSRange(location: r[0].lowerBound, length: r[0].count))
                == "Your going to love the new search page.")
    }
}
