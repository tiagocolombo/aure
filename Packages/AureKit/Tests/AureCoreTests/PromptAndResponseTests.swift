import Foundation
import Testing
@testable import AureCore

@Suite struct PromptBuilderTests {
    @Test(arguments: Tone.allCases, [CheckMode.correct, .rewrite])
    func promptMentionsToneAndMode(tone: Tone, mode: CheckMode) {
        let p = PromptBuilder.build(CheckRequest(text: "hello wrold", tone: tone, mode: mode))
        #expect(p.system.contains(tone.displayName))
        #expect(p.system.contains(mode == .correct ? "proofread" : "rewrite"))
        #expect(p.user.hasPrefix("hello wrold"))
        #expect(p.user.hasSuffix("/no_think"))
        #expect(p.temperature == (mode == .correct ? 0.2 : 0.6))
        #expect(!p.examples.isEmpty)
        #expect(p.examples.allSatisfy { !$0.assistant.hasPrefix("{") && !$0.assistant.isEmpty })
    }

    @Test func dialectNotes() {
        let us = PromptBuilder.build(CheckRequest(text: "x", tone: .formal, dialect: .enUS))
        let ca = PromptBuilder.build(CheckRequest(text: "x", tone: .formal, dialect: .enCA))
        #expect(us.system.contains("American English"))
        #expect(ca.system.contains("colour"))
        #expect(ca.system.contains("organize"))
        let gb = PromptBuilder.build(CheckRequest(text: "x", tone: .formal, dialect: .enGB))
        #expect(gb.system.contains("British English"))
        #expect(gb.system.contains("colour"))
        #expect(gb.system.hasPrefix("You are Aure, a precise English copy editor."))
    }

    @Test(arguments: Tone.allCases, [CheckMode.correct, .rewrite])
    func portuguesePromptStaysInPortuguese(tone: Tone, mode: CheckMode) {
        let p = PromptBuilder.build(CheckRequest(text: "Eles vai chegar amanha.", tone: tone, mode: mode, dialect: .ptBR))
        #expect(p.system.hasPrefix("You are Aure, a precise Brazilian Portuguese copy editor."))
        #expect(p.system.contains("never translate"))
        #expect(!p.examples.isEmpty)
        // Portuguese examples, so the model does not answer in English.
        let english = Set(PromptBuilder.fewShot(mode, tone).map(\.text))
        #expect(p.examples.allSatisfy { !english.contains($0.user.replacingOccurrences(of: "\n/no_think", with: "")) })
    }

    @Test func englishPromptListsEnglishConfusedWords() {
        let en = PromptBuilder.build(CheckRequest(text: "x", tone: .formal))
        let pt = PromptBuilder.build(CheckRequest(text: "x", tone: .formal, dialect: .ptBR))
        #expect(en.system.contains("your/you're"))
        #expect(!pt.system.contains("your/you're"))
        #expect(pt.system.contains("mas/mais"))
    }

    @Test func dialectSettingRoundTrips() {
        for setting in DialectSetting.allCases {
            #expect(DialectSetting(rawValue: setting.rawValue) == setting)
        }
        #expect(DialectSetting(rawValue: "auto") == .automatic)
        #expect(DialectSetting(rawValue: "en_CA") == .fixed(.enCA))
        #expect(DialectSetting(rawValue: "fr_FR") == nil)
        #expect(Dialect.english == [.enUS, .enGB, .enCA])
        #expect(Dialect.ptBR.language == .portuguese)
    }

    @Test func styleContextIsIncluded() {
        let style = StyleContext(profileSummary: "Direct and warm.", neverFlag: ["gonna"],
                                 preferences: ["Use the Oxford comma"], dictionary: ["Aure"])
        let p = PromptBuilder.build(CheckRequest(text: "x", tone: .informal), style: style)
        #expect(p.system.contains("Direct and warm."))
        #expect(p.system.contains("gonna"))
        #expect(p.system.contains("Oxford comma"))
        #expect(p.system.contains("Aure"))
    }

    @Test func thinkingCanBeLeftOn() {
        let p = PromptBuilder.build(CheckRequest(text: "x", tone: .formal), disableThinking: false)
        #expect(!p.user.contains("/no_think"))
    }

    @Test(arguments: Tone.allCases)
    func rewritesAskForPlainWordsWithoutDashes(tone: Tone) {
        let rewrite = PromptBuilder.build(CheckRequest(text: "x", tone: tone, mode: .rewrite))
        let correct = PromptBuilder.build(CheckRequest(text: "x", tone: tone, mode: .correct))
        #expect(rewrite.system.contains("Never use em dashes"))
        #expect(!correct.system.contains("Never use em dashes"))
        #expect(!rewrite.system.contains("—"))
        #expect(rewrite.examples.allSatisfy { !$0.assistant.contains("—") })
    }
}

@Suite struct AIStyleCheckTests {
    @Test func promptIsAOneWordVerdictWithBothAnswersShown() {
        let p = AIStyleCheck.prompt(for: "hello")
        #expect(p.user.hasPrefix("hello"))
        #expect(p.temperature == 0)
        #expect(p.maxTokens <= 2)
        #expect(Set(p.examples.map(\.assistant)) == ["yes", "no"])
    }

    private func token(_ text: String, _ p: Double, top: [(String, Double)]) -> TokenLogprob {
        TokenLogprob(bytes: Array(text.utf8), logprob: log(p),
                     top: top.map { .init(bytes: Array($0.0.utf8), logprob: log($0.1)) })
    }

    @Test func readsTheVerdictFromTokenProbabilities() {
        #expect(AIStyleCheck.isAIStyle(answer: "no", tokens: [token("no", 0.45, top: [("yes", 0.55), ("no", 0.45)])]))
        #expect(!AIStyleCheck.isAIStyle(answer: "yes", tokens: [token("yes", 0.3, top: [(" No", 0.7)])]))
    }

    @Test func fallsBackToTheAnswerText() {
        #expect(AIStyleCheck.isAIStyle(answer: " Yes.", tokens: []))
        #expect(!AIStyleCheck.isAIStyle(answer: "no", tokens: []))
        #expect(!AIStyleCheck.isAIStyle(answer: "maybe", tokens: [token("maybe", 0.9, top: [])]))
    }
}

@Suite struct ResponseParserTests {
    @Test func plainTextAnswer() throws {
        #expect(try ResponseParser.parse("You're going home.", original: "Your going home.").corrected == "You're going home.")
    }

    @Test func stripsThinkFencesLabelsAndQuotes() throws {
        #expect(try ResponseParser.parse("<think>\n\n</think>\n\nHi there.", original: "hi there").corrected == "Hi there.")
        #expect(try ResponseParser.parse("```\nHi there.\n```", original: "hi there").corrected == "Hi there.")
        #expect(try ResponseParser.parse("Corrected: Hi there.", original: "hi there").corrected == "Hi there.")
        #expect(try ResponseParser.parse("\"Hi there.\"", original: "hi there").corrected == "Hi there.")
        // Quotes the writer used are kept.
        #expect(try ResponseParser.parse("\"Hi there.\"", original: "\"hi there\"").corrected == "\"Hi there.\"")
    }

    @Test func jsonAnswerStillAccepted() throws {
        let a = try ResponseParser.parse(#"{"corrected":"a {b} c","edits":[{"from":"x","to":"y","category":"grammar","why":"z"}]}"#, original: "a")
        #expect(a.corrected == "a {b} c")
        #expect(a.edits.count == 1)
    }

    @Test func rejectsEmptyAndBadJSON() {
        #expect(throws: AureError.self) { try ResponseParser.parse("   ", original: "hello") }
        #expect(throws: AureError.self) { try ResponseParser.parseJSON(#"{"corrected": "unterminated"#) }
    }
}

@Suite struct ValidatorTests {
    func answer(_ s: String) -> ModelAnswer { ModelAnswer(corrected: s, edits: []) }

    @Test func acceptsSmallCorrection() throws {
        let out = try Validator.validate(original: "I has a question about the report.",
                                         answer: answer("I have a question about the report."), mode: .correct)
        #expect(out == "I have a question about the report.")
    }

    @Test func rejectsOverRewriteInCorrectMode() {
        #expect(throws: AureError.self) {
            try Validator.validate(original: "can u send the file", answer: answer("Would you kindly forward the document to me?"),
                                   mode: .correct)
        }
    }

    @Test func allowsRewriteInRewriteMode() throws {
        _ = try Validator.validate(original: "can u send the file pls", answer: answer("Could you please send the file?"),
                                   mode: .rewrite)
    }

    @Test func dropsHiddenCharactersTheModelAdded() throws {
        // Zero-width space, a right-to-left override and a tag character are invisible in a diff.
        let out = try Validator.validate(original: "Send it to the team today.",
                                         answer: answer("Send it to the\u{200B} team\u{202E} today.\u{E0041}"), mode: .correct)
        #expect(out == "Send it to the team today.")
    }

    @Test func keepsHiddenCharactersTheOriginalHas() {
        let family = "\u{1F469}\u{200D}\u{1F467}" // woman + ZWJ + girl
        #expect(Validator.removingHiddenCharacters("Our \(family) trip\n", keepingThoseIn: "our \(family) trip") == "Our \(family) trip\n")
    }

    @Test func rejectsDroppedURLMentionAndEmoji() {
        #expect(throws: AureError.self) {
            try Validator.validate(original: "see https://x.com/a for info", answer: answer("see the link for info"), mode: .rewrite)
        }
        #expect(throws: AureError.self) {
            try Validator.validate(original: "thanks @maria for teh help", answer: answer("thanks Maria for the help"), mode: .correct)
        }
        #expect(throws: AureError.self) {
            try Validator.validate(original: "great work team 🎉 realy", answer: answer("great work team really"), mode: .correct)
        }
    }

    @Test func urlFollowedByPeriodIsFine() throws {
        _ = try Validator.validate(original: "Read https://example.com/docs. It are good.",
                                   answer: answer("Read https://example.com/docs. It is good."), mode: .correct)
    }

    @Test func restoresOuterWhitespace() throws {
        let out = try Validator.validate(original: "  teh cat\n", answer: answer("the cat"), mode: .correct)
        #expect(out == "  the cat\n")
    }

    @Test func rejectsEmpty() {
        #expect(throws: AureError.self) { try Validator.validate(original: "hello", answer: answer("  "), mode: .correct) }
    }
}

@Suite struct IssueBuilderTests {
    @Test func filtersLowercasingAndDroppedPeriods() {
        #expect(IssueBuilder.filterNoise(original: "ok, I'll check it.", corrected: "ok, i'll check it") == "ok, I'll check it.")
        #expect(IssueBuilder.filterNoise(original: "Their going home.", corrected: "They're going home") == "They're going home.")
        #expect(IssueBuilder.filterNoise(original: "i am here", corrected: "I am here") == "I am here")
        #expect(IssueBuilder.filterNoise(original: "Their going tomorow.", corrected: "They're going tomorrow") == "They're going tomorrow.")
    }

    @Test func usesModelCategoryAndReason() {
        let issues = IssueBuilder.issues(
            original: "the report are ready tomorow",
            corrected: "the report is ready tomorrow",
            edits: [.init(from: "are", to: "is", category: "grammar", why: "Singular subject"),
                    .init(from: "tomorow", to: "tomorrow", category: "spelling", why: "Misspelled")])
        #expect(issues.count == 2)
        #expect(issues[0].category == .grammar)
        #expect(issues[0].explanation == "Singular subject")
        #expect(issues[1].category == .spelling)
    }

    @Test func guessesWhenModelGaveNoEdits() {
        let issues = IssueBuilder.issues(original: "Hi John how are you", corrected: "Hi John, how are you?", edits: [])
        #expect(issues.count == 2)
        #expect(issues.allSatisfy { $0.category == .punctuation })
    }

    @Test func keepsSentenceCapital() {
        #expect(IssueBuilder.filterNoise(original: "Their going home.", corrected: "they're going home.") == "They're going home.")
        #expect(IssueBuilder.filterNoise(original: "Between you and I, ok.", corrected: "Between you and me, ok.") == "Between you and me, ok.")
    }

    @Test func doesNotReuseUnrelatedReasons() {
        let issues = IssueBuilder.issues(original: "Their going tomorow", corrected: "They're going tomorrow",
                                         edits: [.init(from: "Their", to: "They're", category: "grammar", why: "they are")])
        #expect(issues[0].explanation == "they are")
        #expect(issues[1].explanation != "they are")
        #expect(issues[1].category == .spelling)
    }

    @Test func spellingGuess() {
        let issues = IssueBuilder.issues(original: "I recieved it", corrected: "I received it", edits: [])
        #expect(issues.first?.category == .spelling)
    }
}
