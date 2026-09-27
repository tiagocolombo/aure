import Foundation
import CoreGraphics

/// The three writing registers Aure can target.
public enum Tone: String, Codable, CaseIterable, Sendable, Identifiable {
    case informal
    case formal
    case strictFormal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .informal: "Informal"
        case .formal: "Formal"
        case .strictFormal: "Strict formal"
        }
    }
}

/// `correct` makes minimal fixes; `rewrite` rewrites the text in the chosen tone.
public enum CheckMode: String, Codable, CaseIterable, Sendable {
    case correct
    case rewrite
}

/// Supported English dialects. US is the default.
public enum Dialect: String, Codable, CaseIterable, Sendable, Identifiable {
    case enUS = "en_US"
    case enCA = "en_CA"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .enUS: "English (US)"
        case .enCA: "English (Canada)"
        }
    }

    /// Language code understood by `NSSpellChecker`.
    public var spellCheckerLanguage: String { rawValue }
}

public struct CheckRequest: Codable, Hashable, Sendable {
    public var text: String
    public var tone: Tone
    public var mode: CheckMode
    public var dialect: Dialect
    public var appBundleId: String?
    public var host: String?

    public init(text: String, tone: Tone, mode: CheckMode = .correct, dialect: Dialect = .enUS,
                appBundleId: String? = nil, host: String? = nil) {
        self.text = text
        self.tone = tone
        self.mode = mode
        self.dialect = dialect
        self.appBundleId = appBundleId
        self.host = host
    }
}

public struct Issue: Codable, Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case spelling, grammar, punctuation, wordChoice, tone, clarity

        public var displayName: String {
            switch self {
            case .spelling: "Spelling"
            case .grammar: "Grammar"
            case .punctuation: "Punctuation"
            case .wordChoice: "Word choice"
            case .tone: "Tone"
            case .clarity: "Clarity"
            }
        }
    }

    public var id: UUID
    /// UTF-16 offsets into the original text.
    public var range: Range<Int>
    public var original: String
    public var replacement: String
    public var category: Category
    public var explanation: String
    /// How sure the model was that this edit is needed (0...1). 1 when unknown.
    public var confidence: Double

    public init(id: UUID = UUID(), range: Range<Int>, original: String, replacement: String,
                category: Category, explanation: String, confidence: Double = 1) {
        self.id = id
        self.range = range
        self.original = original
        self.replacement = replacement
        self.category = category
        self.explanation = explanation
        self.confidence = confidence
    }
}

public struct CheckResult: Codable, Sendable, Equatable {
    public var request: CheckRequest
    public var corrected: String
    public var issues: [Issue]
    public var latencyMs: Int

    public var hasIssues: Bool { !issues.isEmpty }

    public init(request: CheckRequest, corrected: String, issues: [Issue], latencyMs: Int) {
        self.request = request
        self.corrected = corrected
        self.issues = issues
        self.latencyMs = latencyMs
    }
}

/// A snapshot of a text field in another app (or in Aure Pad).
public struct FieldSnapshot: Sendable, Equatable {
    public var text: String
    public var selection: Range<Int>?
    public var frame: CGRect?
    public var pid: Int32?
    public var bundleId: String?
    public var isSecure: Bool

    public init(text: String, selection: Range<Int>? = nil, frame: CGRect? = nil, pid: Int32? = nil,
                bundleId: String? = nil, isSecure: Bool = false) {
        self.text = text
        self.selection = selection
        self.frame = frame
        self.pid = pid
        self.bundleId = bundleId
        self.isSecure = isSecure
    }
}

public enum AureError: Error, Equatable, Sendable, LocalizedError {
    case modelNotLoaded
    case invalidModelOutput(String)
    case rejected(String)
    case cancelled
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "No model is loaded. Download or select one in Settings → Models."
        case .invalidModelOutput(let s): "The model returned an unreadable answer (\(s))."
        case .rejected(let s): "The suggestion was discarded: \(s)."
        case .cancelled: "Cancelled."
        case .server(let s): "Model server error: \(s)"
        }
    }
}
