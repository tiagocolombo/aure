import Foundation

/// Style information that personalizes prompts. Filled from the voice profile
/// and learning data (Phase 5); empty by default.
public struct StyleContext: Sendable, Hashable {
    public var profileSummary: String
    public var neverFlag: [String]
    public var preferences: [String]
    public var dictionary: [String]

    public init(profileSummary: String = "", neverFlag: [String] = [], preferences: [String] = [],
                dictionary: [String] = []) {
        self.profileSummary = profileSummary
        self.neverFlag = neverFlag
        self.preferences = preferences
        self.dictionary = dictionary
    }

    public static let empty = StyleContext()
}

/// Editable definition of a tone (Settings → Voice & Tone).
public struct ToneDefinition: Codable, Sendable, Equatable {
    public var tone: Tone
    public var description: String

    public init(tone: Tone, description: String) {
        self.tone = tone
        self.description = description
    }
    public static func `default`(_ tone: Tone) -> ToneDefinition {
        switch tone {
        case .informal:
            ToneDefinition(tone: tone, description: """
            Casual and friendly, like a message to a teammate on Slack. Contractions are fine. \
            Keep emoji, slang the writer chose, and short sentences. Only fix real mistakes; \
            never make it sound stiff.
            """)
        case .formal:
            ToneDefinition(tone: tone, description: """
            Professional email register. Clear, complete sentences and polite wording. No slang. \
            Contractions are acceptable when natural. Keep the writer's structure and greeting.
            """)
        case .strictFormal:
            ToneDefinition(tone: tone, description: """
            Strictly formal register for executives, legal or official correspondence. No \
            contractions, no colloquialisms, no emoji, no exclamation marks. Precise vocabulary \
            and complete salutations and sign-offs.
            """)
        }
    }
}

public struct Prompt: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        public var user: String
        public var assistant: String
    }

    public var system: String
    /// Few-shot examples, sent as real chat turns before `user`.
    public var examples: [Turn]
    public var user: String
    public var temperature: Double
    public var maxTokens: Int
}

public enum PromptBuilder {
    public static func dialectNote(_ d: Dialect) -> String {
        switch d {
        case .enUS:
            "Use American English spelling and punctuation (color, center, organize, analyze)."
        case .enCA:
            """
            Use Canadian English spelling: British-style -our and -re endings (colour, favour, \
            centre, theatre), doubled L (travelled, cancelled), "cheque", "defence", \
            but American -ize/-yze endings (organize, realize, analyze). Never flag these \
            Canadian spellings as errors.
            """
        }
    }

    public static func build(_ req: CheckRequest,
                             toneDefinition: ToneDefinition? = nil,
                             style: StyleContext = .empty,
                             disableThinking: Bool = true) -> Prompt {
        let tone = toneDefinition ?? .default(req.tone)
        var s = "You are Aure, a precise English copy editor.\n"

        switch req.mode {
        case .correct:
            s += """
            Task: proofread the user's text and fix every error: spelling, grammar, punctuation \
            and wrong words. Read each word in context. Pay special attention to commonly confused \
            words that spell checkers miss (for example your/you're, its/it's, their/there/they're, \
            then/than, should of/should have, affect/effect, lose/loose), subject-verb agreement \
            and missing apostrophes. Change only what is wrong and keep everything else exactly \
            as written, including the writer's capitalization style. If the text has no errors, \
            repeat it exactly.

            """
        case .rewrite:
            s += """
            Task: rewrite the user's text in the target tone while keeping its meaning, facts, \
            names and intent. Fix all errors. Keep roughly the same length.

            """
        }

        s += "Target tone — \(tone.tone.displayName): \(tone.description)\n"
        s += dialectNote(req.dialect) + "\n"

        s += """
        Rules:
        - Keep line breaks, lists, URLs, email addresses, @mentions, #channels, `code`, numbers and emoji exactly as written.
        - Keep names and technical terms. Do not add greetings, sign-offs or new content.
        - Reply with the corrected text only: no quotes, labels, explanations or notes.

        """

        if !style.profileSummary.isEmpty {
            s += "Writer's voice (keep it): \(style.profileSummary)\n"
        }
        if !style.preferences.isEmpty {
            s += "Writer's preferences:\n" + style.preferences.prefix(20).map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !style.neverFlag.isEmpty {
            s += "Never change these: " + style.neverFlag.prefix(20).joined(separator: ", ") + "\n"
        }
        if !style.dictionary.isEmpty {
            s += "Correctly spelled words (do not flag): " + style.dictionary.prefix(40).joined(separator: ", ") + "\n"
        }

        let suffix = disableThinking ? "\n/no_think" : ""
        let examples = fewShot(req.mode, req.tone).map {
            Prompt.Turn(user: $0.text + suffix, assistant: $0.corrected)
        }
        let user = req.text + suffix

        let approxTokens = max(16, req.text.utf8.count / 3)
        return Prompt(system: s,
                      examples: examples,
                      user: user,
                      temperature: req.mode == .correct ? 0.2 : 0.6,
                      maxTokens: min(2048, approxTokens * 2 + 64))
    }

    static func fewShot(_ mode: CheckMode, _ tone: Tone) -> [(text: String, corrected: String)] {
        let raw: String
        switch (mode, tone) {
        case (.correct, .informal):
            raw = """
            Text: hey, their going to be late lol. can u tell the others?
            {"corrected":"hey, they're going to be late lol. can u tell the others?","edits":[{"from":"their","to":"they're","category":"grammar","why":"'they're' means 'they are'"}]}
            Text: sounds good 👍 see you at 3
            {"corrected":"sounds good 👍 see you at 3","edits":[]}
            Text: your right, its too late to change it now
            {"corrected":"you're right, it's too late to change it now","edits":[{"from":"your","to":"you're","category":"grammar","why":"'you're' means 'you are'"},{"from":"its","to":"it's","category":"grammar","why":"'it's' means 'it is'"}]}
            Text: we should of merged it, lets fix it when your back
            {"corrected":"we should have merged it, let's fix it when you're back","edits":[{"from":"should of","to":"should have","category":"grammar","why":"'should have', not 'should of'"},{"from":"lets","to":"let's","category":"punctuation","why":"Contraction of 'let us'"},{"from":"your","to":"you're","category":"grammar","why":"'you're' means 'you are'"}]}
            """
        case (.correct, _):
            raw = """
            Text: Hi Anna, I wanted to let you know that the report are ready and I will send it tomorow.
            {"corrected":"Hi Anna, I wanted to let you know that the report is ready and I will send it tomorrow.","edits":[{"from":"are","to":"is","category":"grammar","why":"Subject 'report' is singular"},{"from":"tomorow","to":"tomorrow","category":"spelling","why":"Misspelled word"}]}
            Text: Thank you for your help with the proposal.
            {"corrected":"Thank you for your help with the proposal.","edits":[]}
            Text: Your welcome to join, but there coming at 9 and its a long meeting.
            {"corrected":"You're welcome to join, but they're coming at 9 and it's a long meeting.","edits":[{"from":"Your","to":"You're","category":"grammar","why":"'You're' means 'you are'"},{"from":"there","to":"they're","category":"grammar","why":"'they're' means 'they are'"},{"from":"its","to":"it's","category":"grammar","why":"'it's' means 'it is'"}]}
            Text: We received less applications then last year.
            {"corrected":"We received fewer applications than last year.","edits":[{"from":"less","to":"fewer","category":"wordChoice","why":"Use 'fewer' with countable nouns"},{"from":"then","to":"than","category":"wordChoice","why":"'than' is used for comparisons"}]}
            """
        case (.rewrite, .informal):
            raw = """
            Text: I would like to inform you that the meeting has been moved to Friday.
            {"corrected":"Heads up, the meeting moved to Friday.","edits":[{"from":"I would like to inform you that the meeting has been moved","to":"Heads up, the meeting moved","category":"tone","why":"More casual phrasing"}]}
            """
        case (.rewrite, .formal):
            raw = """
            Text: hey can u send me the numbers asap, need them for the call
            {"corrected":"Hi, could you please send me the numbers as soon as possible? I need them for the call.","edits":[{"from":"hey can u send me the numbers asap, need them","to":"Hi, could you please send me the numbers as soon as possible? I need them","category":"tone","why":"Professional wording"}]}
            """
        case (.rewrite, .strictFormal):
            raw = """
            Text: Hi Tom, thanks! We can't make it Monday, can we do Tuesday?
            {"corrected":"Dear Tom, thank you. Unfortunately, we are unable to attend on Monday. Would Tuesday be convenient?","edits":[{"from":"Hi Tom, thanks! We can't make it Monday, can we do Tuesday?","to":"Dear Tom, thank you. Unfortunately, we are unable to attend on Monday. Would Tuesday be convenient?","category":"tone","why":"Strictly formal register"}]}
            """
        }
        var out: [(text: String, corrected: String)] = []
        var pending: String?
        for line in raw.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasPrefix("Text: ") {
                pending = String(line.dropFirst(6))
            } else if let t = pending, let corrected = ((try? ResponseParser.parseJSON(line))?.corrected) {
                out.append((t, corrected))
                pending = nil
            }
        }
        return out
    }
}
