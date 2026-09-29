import AppKit
import AureCore
import Foundation
import Testing
@testable import AureInference

@Suite struct DialectDetectorTests {
    @Test func fewestRejectedWordsWins() {
        #expect(DialectDetector.englishVariant(rejected: [.enUS: 2, .enGB: 0, .enCA: 1], preferred: .enUS) == .enGB)
        #expect(DialectDetector.englishVariant(rejected: [.enUS: 0, .enGB: 2, .enCA: 2], preferred: .enGB) == .enUS)
    }

    @Test func tieKeepsPreferredVariant() {
        #expect(DialectDetector.englishVariant(rejected: [.enUS: 1, .enGB: 1, .enCA: 1], preferred: .enCA) == .enCA)
        #expect(DialectDetector.englishVariant(rejected: [.enUS: 3, .enGB: 0, .enCA: 0], preferred: .enCA) == .enCA)
        #expect(DialectDetector.englishVariant(rejected: [.enUS: 3, .enGB: 0, .enCA: 0], preferred: .enUS) == .enGB)
        #expect(DialectDetector.englishVariant(rejected: [:], preferred: .enGB) == .enGB)
    }

    @Test func systemDefaultFollowsPreferredLanguages() {
        #expect(DialectDetector.systemDefault(preferredLanguages: ["en-GB"]) == .enGB)
        #expect(DialectDetector.systemDefault(preferredLanguages: ["en-CA", "fr-CA"]) == .enCA)
        #expect(DialectDetector.systemDefault(preferredLanguages: ["pt-BR", "en-US"]) == .ptBR)
        #expect(DialectDetector.systemDefault(preferredLanguages: ["fr-FR", "en-AU"]) == .enGB)
        #expect(DialectDetector.systemDefault(preferredLanguages: ["en"]) == .enUS)
        #expect(DialectDetector.systemDefault(preferredLanguages: ["ja-JP"]) == .enUS)
    }

    @Test @MainActor func shortTextKeepsFallback() {
        let r = DialectDetector.detect("ok, thx", fallback: .ptBR)
        #expect(r == .init(dialect: .ptBR, detected: false))
    }

    @Test @MainActor func detectsBrazilianPortuguese() {
        let r = DialectDetector.detect("Oi, pessoal! A reunião de amanhã foi transferida para sexta-feira à tarde.",
                                       fallback: .enUS)
        #expect(r == .init(dialect: .ptBR, detected: true))
    }

    @Test @MainActor func detectsEnglish() {
        let r = DialectDetector.detect("Hi team, the meeting tomorrow has moved to Friday afternoon.", fallback: .ptBR)
        #expect(r.detected)
        #expect(r.dialect.language == .english)
    }

    @Test @MainActor func spellingPicksTheVariant() {
        let available = NSSpellChecker.shared.availableLanguages
        guard available.contains("en_US"), available.contains("en_GB") else { return }
        let us = DialectDetector.detect("I love the color of the theater downtown, it is my favorite place.",
                                        fallback: .enGB)
        #expect(us.dialect == .enUS)
        let uk = DialectDetector.detect("I love the colour of the theatre in the centre, it is my favourite place.",
                                        fallback: .enUS)
        #expect(uk.dialect != .enUS)
    }

    struct CorpusCase: Decodable {
        var text: String
        var expect: String
        var fallback: String
    }

    /// eval/languages/detection.jsonl: language must always be right; the English
    /// variant depends on the Mac's dictionaries, so it only needs to be mostly right.
    @Test @MainActor func detectionCorpus() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("eval/languages/detection.jsonl")
        let cases = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(CorpusCase.self, from: Data($0.utf8))
        }
        #expect(cases.count > 50)
        var variantHits = 0, variantTotal = 0
        for c in cases {
            let fallback = try #require(Dialect(rawValue: c.fallback))
            let r = DialectDetector.detect(c.text, fallback: fallback)
            if c.expect == "fallback" {
                #expect(r == .init(dialect: fallback, detected: false), "\(c.text)")
                continue
            }
            let want = try #require(Dialect(rawValue: c.expect))
            #expect(r.detected, "\(c.text)")
            #expect(r.dialect.language == want.language, "\(c.text)")
            if want.language == .english {
                variantTotal += 1
                if r.dialect == want { variantHits += 1 }
            }
        }
        #expect(Double(variantHits) >= 0.8 * Double(variantTotal), "\(variantHits)/\(variantTotal) English variants")
    }
}
