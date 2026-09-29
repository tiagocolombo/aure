import AppKit
import AureCore
import Foundation
import NaturalLanguage

/// Picks the dialect to check a text in when the language setting is
/// "Detect automatically". Runs on the Mac, without the model:
///
/// 1. `NLLanguageRecognizer` decides English or Portuguese.
/// 2. For English, the system spell checker votes: each variant's dictionary
///    (US, UK, Canada) counts the words it would reject, and the variant that
///    rejects the fewest wins. "colour" counts against US; "color" against UK.
///    Real typos count against every variant, so they do not tip the vote.
///
/// Short or unclear text keeps `fallback` (usually the last detected dialect),
/// so a two-word reply does not flip the language.
public enum DialectDetector {
    /// Below this many letters the language guess is not trusted.
    static let minimumLetters = 12
    /// `NLLanguageRecognizer` probability needed to switch language.
    static let minimumConfidence = 0.6
    /// Only this much of a long text is examined; the start is enough to tell.
    static let sampleLength = 2000

    public struct Result: Equatable, Sendable {
        public var dialect: Dialect
        /// False when the text was too short or unclear and `fallback` was used.
        public var detected: Bool
    }

    @MainActor
    public static func detect(_ text: String, fallback: Dialect) -> Result {
        let sample = String(text.utf16.prefix(sampleLength)) ?? text
        guard let language = language(of: sample) else { return Result(dialect: fallback, detected: false) }
        switch language {
        case .portuguese:
            return Result(dialect: .ptBR, detected: true)
        case .english:
            let checker = NSSpellChecker.shared
            let available = Set(checker.availableLanguages)
            let candidates = Dialect.english.filter { available.contains($0.spellCheckerLanguage) }
            var rejected: [Dialect: Int] = [:]
            for d in candidates {
                rejected[d] = misspelledCount(in: sample, language: d.spellCheckerLanguage, checker: checker)
            }
            let preferred = fallback.language == .english ? fallback : .enUS
            return Result(dialect: englishVariant(rejected: rejected, preferred: preferred), detected: true)
        }
    }

    /// The language of `text`, or nil when it is too short or unclear.
    static func language(of text: String) -> Dialect.Language? {
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .portuguese]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        guard let best = hypotheses.max(by: { $0.value < $1.value }), best.value >= minimumConfidence else { return nil }
        switch best.key {
        case .english: return .english
        case .portuguese: return .portuguese
        default: return nil
        }
    }

    /// The English variant whose dictionary rejected the fewest words. Ties
    /// (e.g. text with no variant-specific words) keep `preferred`.
    static func englishVariant(rejected: [Dialect: Int], preferred: Dialect) -> Dialect {
        guard let fewest = rejected.values.min() else { return preferred }
        let tied = Dialect.english.filter { rejected[$0] == fewest }
        if tied.contains(preferred) { return preferred }
        return tied.first ?? preferred
    }

    @MainActor
    static func misspelledCount(in text: String, language: String, checker: NSSpellChecker) -> Int {
        let length = (text as NSString).length
        var count = 0
        var offset = 0
        while offset < length {
            let r = checker.checkSpelling(of: text, startingAt: offset, language: language,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard r.location != NSNotFound, r.length > 0 else { break }
            count += 1
            offset = r.location + r.length
        }
        return count
    }

    /// The dialect to assume before anything has been detected, from the
    /// Mac's preferred languages (e.g. "en-GB" → UK, "pt-BR" → Portuguese).
    public static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> Dialect {
        for id in preferredLanguages {
            let parts = id.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let lang = parts.first?.lowercased() else { continue }
            let region = parts.dropFirst().first { $0.count == 2 }?.uppercased()
            switch lang {
            case "pt": return .ptBR
            case "en":
                switch region {
                case "GB", "IE", "AU", "NZ", "ZA", "IN": return .enGB
                case "CA": return .enCA
                default: return .enUS
                }
            default: continue
            }
        }
        return .enUS
    }
}
