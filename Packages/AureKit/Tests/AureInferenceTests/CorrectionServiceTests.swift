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

    @Test func canadianSpellingIsNotFlagged() async throws {
        let svc = CorrectionService(provider: FakeLLMProvider(corrected: "I love the colour of the centre."))
        let r = try await svc.check(CheckRequest(text: "I love the colour of the centre.", tone: .formal, dialect: .enCA))
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
