import AureCore
import Foundation
import Testing
@testable import AureInference

@Suite struct CorrectionServiceTests {
    @Test func producesIssuesFromFakeModel() async throws {
        let fake = FakeLLMProvider(corrected: "They're going to the store tomorrow.",
                                   edits: [.init(from: "Their", to: "They're", category: "grammar", why: "Contraction of they are")])
        let svc = CorrectionService(provider: fake)
        let r = try await svc.check(CheckRequest(text: "Their going to the store tomorow.", tone: .formal))
        #expect(r.corrected == "They're going to the store tomorrow.")
        #expect(r.issues.count == 2)
        #expect(r.issues[0].category == .grammar)
        #expect(r.issues[0].explanation == "Contraction of they are")
    }

    @Test func cleanTextIsGreen() async throws {
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: "All good here."))
        let r = try await svc.check(CheckRequest(text: "All good here.", tone: .informal))
        #expect(!r.hasIssues)
    }

    @Test func cachesIdenticalRequests() async throws {
        let fake = FakeLLMProvider(corrected: "Hello there.")
        let svc = CorrectionService(provider: fake)
        let req = CheckRequest(text: "Hello there.", tone: .formal)
        _ = try await svc.check(req)
        _ = try await svc.check(req)
        #expect(fake.callCount == 1)
    }

    @Test func noProviderThrowsModelNotLoaded() async {
        let svc = CorrectionService()
        await #expect(throws: AureError.modelNotLoaded) {
            try await svc.check(CheckRequest(text: "Hi there friend", tone: .formal))
        }
    }

    @Test func rejectsOverRewrite() async {
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: "Kindly forward the document at your earliest convenience."))
        await #expect(throws: AureError.self) {
            try await svc.check(CheckRequest(text: "can u send the file pls", tone: .formal, mode: .correct))
        }
    }

    @Test func dictionaryWordsAreNeverChanged() async throws {
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: "Ask Aura about the Kubernetes rollout."))
        await svc.setStyle(StyleContext(dictionary: ["Aure"]))
        let r = try await svc.check(CheckRequest(text: "Ask Aure about the Kubernetes rollout.", tone: .formal))
        #expect(r.corrected == "Ask Aure about the Kubernetes rollout.")
        #expect(!r.hasIssues)
    }

    @Test func spellCheckerCatchesMissedTypo() async throws {
        // The model misses "recieve"; NSSpellChecker should flag it.
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: "Did you recieve my email?"))
        let r = try await svc.check(CheckRequest(text: "Did you recieve my email?", tone: .formal))
        #expect(r.issues.contains { $0.original == "recieve" && $0.replacement == "receive" })
        #expect(r.corrected == "Did you receive my email?")
    }

    @Test func realWordSwapIsWordChoiceNotSpelling() async throws {
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: "You're going to the school tomorrow."))
        let r = try await svc.check(CheckRequest(text: "Your going to the school tomorrow.", tone: .formal))
        #expect(r.issues.count == 1)
        #expect(r.issues[0].category == .wordChoice)
    }

    @Test func lowConfidenceEditsAreHidden() async throws {
        // Model output drops "the" (keeping it had p ≈ 0.39) and fixes "Your" (p(keep) ≈ 0).
        @Sendable func tok(_ s: String, _ alts: [(String, Double)] = []) -> TokenLogprob {
            TokenLogprob(bytes: Array(s.utf8), logprob: 0,
                         top: [.init(bytes: Array(s.utf8), logprob: 0)] + alts.map { .init(bytes: Array($0.0.utf8), logprob: $0.1) })
        }
        let fake = FakeLLMProvider { _, _ in
            LLMCompletion(text: "You're going to school tomorrow.",
                          tokens: [tok("You", [("Your", -9.4)]), tok("'re"), tok(" going"), tok(" to"),
                                   tok(" school", [(" the", -0.93)]), tok(" tomorrow"), tok(".")])
        }
        let svc = CorrectionService(provider: fake)
        let req = CheckRequest(text: "Your going to the school tomorrow.", tone: .formal)

        let all = try await svc.check(req)
        #expect(all.issues.count == 2)

        await svc.setMinConfidence(0.9)
        let sure = try await svc.check(req)
        #expect(sure.issues.count == 1)
        #expect(sure.corrected == "You're going to the school tomorrow.")
    }

    @Test func longTextIsCheckedPieceByPiece() async throws {
        // The fake model fixes whatever single piece it gets; offsets must map back.
        let fake = FakeLLMProvider { _, user in
            let text = user.replacingOccurrences(of: "\n/no_think", with: "")
            return text.replacingOccurrences(of: "report are", with: "report is")
                .replacingOccurrences(of: "if your available", with: "if you're available")
        }
        let svc = CorrectionService(provider: fake)
        let email = "Hi Sarah 🎉,\n\nThe report are ready for review.\n\nLet me know if your available on Thursday.\n\nThanks,\nTiago"
        let r = try await svc.check(CheckRequest(text: email, tone: .formal))
        #expect(await fake.calls.count == 2) // two paragraphs; greeting and sign-off skipped
        #expect(r.issues.count == 2)
        #expect(r.corrected == "Hi Sarah 🎉,\n\nThe report is ready for review.\n\nLet me know if you're available on Thursday.\n\nThanks,\nTiago")
        for i in r.issues {
            #expect((email as NSString).substring(with: NSRange(location: i.range.lowerBound, length: i.range.count)) == i.original)
        }
    }

    @Test func oneRejectedPieceDoesNotHideTheOthers() async throws {
        let fake = FakeLLMProvider { _, user in
            let text = user.replacingOccurrences(of: "\n/no_think", with: "")
            if text.hasPrefix("First") { return "Something completely different was written here instead." }
            return text.replacingOccurrences(of: "doesn't run", with: "don't run")
        }
        let svc = CorrectionService(provider: fake)
        let text = "First paragraph is perfectly fine as it is.\n\nThe reporting jobs doesn't run yet."
        let r = try await svc.check(CheckRequest(text: text, tone: .formal))
        #expect(r.corrected == "First paragraph is perfectly fine as it is.\n\nThe reporting jobs don't run yet.")
    }

    @Test func paragraphsRunInParallelUpToTheLimit() async throws {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var now = 0, peak = 0
            func enter() { lock.withLock { now += 1; peak = max(peak, now) } }
            func leave() { lock.withLock { now -= 1 } }
        }
        let gauge = Gauge()
        let fake = FakeLLMProvider { _, user in
            gauge.enter()
            defer { gauge.leave() }
            try await Task.sleep(for: .milliseconds(80))
            return user.replacingOccurrences(of: "\n/no_think", with: "")
                .replacingOccurrences(of: "are ready", with: "is ready")
        }
        let svc = CorrectionService(provider: fake)
        await svc.setMaxParallel(3)
        let paragraphs = (1...6).map { "Paragraph number \($0) of the report are ready." }
        let text = paragraphs.joined(separator: "\n\n")
        let r = try await svc.check(CheckRequest(text: text, tone: .formal))
        #expect(gauge.peak == 3)
        #expect(r.issues.count == 6)
        #expect(r.issues.map(\.range.lowerBound) == r.issues.map(\.range.lowerBound).sorted())
        #expect(r.corrected == paragraphs.map { $0.replacingOccurrences(of: "are ready", with: "is ready") }
            .joined(separator: "\n\n"))
    }

    @Test func canadianSpellingIsNotFlagged() async throws {
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: "I love the colour of the centre."))
        let r = try await svc.check(CheckRequest(text: "I love the colour of the centre.", tone: .formal, dialect: .enCA))
        #expect(!r.hasIssues)
    }

    @Test func britishSpellingIsNotFlagged() async throws {
        let text = "We travelled to the theatre to analyse the programme."
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: text))
        let r = try await svc.check(CheckRequest(text: text, tone: .formal, dialect: .enGB))
        #expect(!r.hasIssues)
    }

    @Test func cancellationPropagates() async {
        let fake = FakeLLMProvider { _, _ in
            try await Task.sleep(for: .seconds(5))
            return #"{"corrected":"x","edits":[]}"#
        }
        let svc = CorrectionService(provider: fake)
        let t = Task { try await svc.check(CheckRequest(text: "some text here", tone: .formal)) }
        try? await Task.sleep(for: .milliseconds(100))
        t.cancel()
        let result = await t.result
        #expect(throws: (any Error).self) { try result.get() }
    }
}
