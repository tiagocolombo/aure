import Foundation
import Testing
@testable import AureCore

@Suite struct EditConfidenceTests {
    func tok(_ s: String, _ lp: Double, _ alts: [(String, Double)] = []) -> TokenLogprob {
        TokenLogprob(bytes: Array(s.utf8), logprob: lp,
                     top: [.init(bytes: Array(s.utf8), logprob: lp)] + alts.map { .init(bytes: Array($0.0.utf8), logprob: $0.1) })
    }

    @Test func confidentWordSwap() throws {
        // Real Qwen3 4B output for "Your going to the school tomorrow."
        let tokens = [
            tok("You", -0.0001, [("Your", -9.4)]),
            tok(" are", -0.2, [("'re", -1.71)]),
            tok(" going", 0), tok(" to", 0),
            tok(" school", -0.502, [(" the", -0.93)]),
            tok(" tomorrow", 0), tok(".", 0),
        ]
        let scored = try #require(EditConfidence.score(original: "Your going to the school tomorrow.",
                                                       output: "You are going to school tomorrow.", tokens: tokens))
        #expect(scored.count == 2)
        // "Your" -> "You are": keeping "Your" had probability e^-9.4.
        #expect(scored[0].hunk.original.hasPrefix("Your"))
        #expect(scored[0].confidence > 0.99)
        // Dropping "the": keeping it had probability e^-0.93 ≈ 0.39.
        #expect(scored[1].hunk.original.contains("the"))
        #expect(abs(scored[1].confidence - (1 - exp(-0.93))) < 0.01)
    }

    @Test func noLogprobsMeansFullConfidence() throws {
        let tokens = [tok("I", 0), tok(" have", 0), tok(" it", 0)]
        let scored = try #require(EditConfidence.score(original: "I has it", output: "I have it", tokens: tokens))
        #expect(scored.count == 1)
        #expect(scored[0].confidence == 1)
    }

    @Test func insertionScoresTheInsertedToken() throws {
        // "Hi John how" -> "Hi John, how": keeping the space instead of the comma had p = e^-2.
        let tokens = [tok("Hi", 0), tok(" John", 0), tok(",", -0.14, [(" how", -2.0)]), tok(" how", 0)]
        let scored = try #require(EditConfidence.score(original: "Hi John how", output: "Hi John, how", tokens: tokens))
        #expect(scored.count == 1)
        #expect(abs(scored[0].confidence - (1 - exp(-2.0))) < 0.01)
    }

    @Test func emojiSplitAcrossTokensAligns() throws {
        // The emoji's UTF-8 bytes are split over two tokens, as llama.cpp does.
        let party = Array("🎉".utf8)
        let tokens = [
            tok("great", 0), tok(" job", 0),
            TokenLogprob(bytes: [32] + party.prefix(2), logprob: 0, top: []),
            TokenLogprob(bytes: Array(party.suffix(2)), logprob: 0, top: []),
            tok(" the", -0.1, [(" teh", -5)]), tok(" team", 0),
        ]
        let scored = try #require(EditConfidence.score(original: "great job 🎉 teh team",
                                                       output: "great job 🎉 the team", tokens: tokens))
        #expect(scored.count == 1)
        #expect(scored[0].confidence > 0.99)
    }

    @Test func misalignedTokensReturnNil() {
        #expect(EditConfidence.score(original: "a b", output: "a c", tokens: [tok("zzz", 0)]) == nil)
    }

    @Test func applyUsesLowestOverlappingConfidence() {
        let hunk = DiffEngine.Hunk(range: 0..<4, original: "Your", replacement: "You're")
        let issue = Issue(range: 0..<4, original: "Your", replacement: "You're", category: .grammar, explanation: "")
        let other = Issue(range: 10..<12, original: "ab", replacement: "cd", category: .spelling, explanation: "")
        let out = EditConfidence.apply([(hunk, 0.4)], to: [issue, other])
        #expect(out[0].confidence == 0.4)
        #expect(out[1].confidence == 1)
    }
}
