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
            and formal salutations and sign-offs where the writer used them.
            """)
        }
    }
}

/// Instruction wording for `correct` mode. Compared in docs/MODEL_EVAL.md.
public enum PromptStyle: String, Sendable, CaseIterable {
    /// Aure's own proofreading prompt.
    case aure
    /// Lines from the prompt Grammarly researchers optimized for GPT-4o
    /// (APIO, Chernodub et al., RANLP 2025, arXiv:2508.09378).
    case grammarlyAPIO
    /// Minimal-edit prompt with the 25 ERRANT error types, as optimized for
    /// Qwen3-8B by Karpo and Chernodub (EMNLP 2026 Findings, arXiv:2609.10810).
    /// Source: github.com/katerynkarpo/llm-en-gec (MIT License).
    case minimalTaxonomy
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
                             promptStyle: PromptStyle = .aure,
                             disableThinking: Bool = true) -> Prompt {
        let tone = toneDefinition ?? .default(req.tone)
        var s = "You are Aure, a precise English copy editor.\n"

        switch (req.mode, promptStyle) {
        case (.correct, .grammarlyAPIO):
            s += """
            *Given a text with grammatical errors, identify and correct the mistakes to produce a \
            grammatically accurate version of the text.
            *Ensure that the corrected text matches the original phrasing, structure, and punctuation \
            as closely as possible while correcting grammatical errors, with a priority on minimizing \
            the number of differing words.
            *Identify any grammatical, spelling or word errors in the provided text and correct them, \
            ensuring the text is grammatically accurate. If the text is already correct, leave it unchanged.

            """
        case (.correct, .minimalTaxonomy):
            s += Self.minimalTaxonomyPrompt + "\n\n"
        case (.correct, .aure):
            s += """
            Task: proofread the user's text and fix every error: spelling, grammar, punctuation \
            and wrong words. Read each word in context. Pay special attention to commonly confused \
            words that spell checkers miss (for example your/you're, its/it's, their/there/they're, \
            then/than, should of/should have, affect/effect, lose/loose), subject-verb agreement \
            and missing apostrophes. Change only what is wrong and keep everything else exactly \
            as written, including the writer's capitalization style. If the text has no errors, \
            repeat it exactly.

            """
        case (.rewrite, _):
            s += """
            Task: rewrite the user's text in the target tone while keeping its meaning, facts, \
            names and intent. Fix all errors. Make it clearer and more direct: cut filler and \
            redundant words, prefer the active voice, and replace wordy phrases with plain ones. \
            Every word of the tone must fit it, so remove casual words from formal text and stiff \
            words from informal text. Never add facts, reasons, excuses, names or placeholders \
            like [Name] that the writer did not write, and keep the same tense and commitments. \
            Do not swap words for synonyms just to be different. If the text is already clear \
            and fits the tone, repeat it exactly.
            Write like a person, not a chatbot: use plain everyday words instead of jargon and \
            buzzwords (for example leverage, seamless, robust, delve, synergy, landscape), and \
            cut hype and filler openers such as "Great question" or "I hope this finds you well".

            """
        }

        s += "Target tone: \(tone.tone.displayName). \(tone.description)\n"
        s += dialectNote(req.dialect) + "\n"

        // Em dashes are also blocked during generation (AIStyleCheck.bannedDashes);
        // the rule tells the model what to use instead.
        let replyRules = req.mode == .rewrite
            ? """
              - Never use em dashes. Use a comma, a period or parentheses instead.
              - Reply with the rewritten text only: no quotes, labels, explanations or notes.
              """
            : "- Reply with the corrected text only: no quotes, labels, explanations or notes."
        s += """
        Rules:
        - Keep line breaks, lists, URLs, email addresses, @mentions, #channels, `code`, numbers and emoji exactly as written.
        - Keep names and technical terms. Do not add greetings, sign-offs or new content.
        \(replyRules)

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

    /// Karpo & Chernodub, A.6.1 (MIT License, github.com/katerynkarpo/llm-en-gec).
    /// Only change: the SPELL example "color→colour" is dropped, because the
    /// dialect note decides US vs Canadian spelling.
    static let minimalTaxonomyPrompt = """
    You are a grammatical error correction system. Make MINIMAL, PRECISE edits to fix errors. DO NOT rewrite or paraphrase. Only fix clear grammatical and spelling errors.

    Focus on these 25 error types:

    WORD-LEVEL ERRORS:
    1. ADJ: Wrong adjective choice (big→wide)
    2. ADJ:FORM: Adjective form errors - comparatives/superlatives (goodest→best, more easy→easier)
    3. ADV: Wrong adverb choice (speedily→quickly)
    4. CONJ: Wrong conjunction (and→but)
    5. CONTR: Contraction errors (n't→not)
    6. DET: Wrong/missing/extra determiner (the→a, ∅→the, the→∅)
    7. NOUN: Wrong noun choice (person→people)
    8. NOUN:INFL: Count-mass noun errors (informations→information)
    9. NOUN:NUM: Noun number agreement (cat→cats)
    10. NOUN:POSS: Noun possessive errors (friends→friend's)
    11. PART: Wrong particle (look in→look at)
    12. PREP: Wrong/missing/extra preposition (of→at, ∅→at, at→∅)
    13. PRON: Wrong pronoun (ours→ourselves)
    14. VERB: Wrong verb choice (ambulate→walk)
    15. VERB:FORM: Verb form errors - infinitive/gerund/participle (to eat→eating, dancing→danced)
    16. VERB:INFL: Verb inflection errors (getted→got, fliped→flipped)
    17. VERB:SVA: Subject-verb agreement ((He) have→(He) has)
    18. VERB:TENSE: Verb tense errors including modals and passive (eats→ate, eats→can eat, eats→was eaten)

    MECHANICAL ERRORS:
    19. ORTH: Orthography - capitalization/whitespace (Bestfriend→best friend, THIS→this)
    20. PUNCT: Punctuation errors (!→., missing commas, extra periods)
    21. SPELL: Spelling errors (genectic→genetic)
    22. WO: Word order errors (only can→can only)

    OTHER:
    23. MORPH: Morphology - same lemma, different part of speech (quick[adj]→quickly[adv])
    24. OTHER: Complex errors requiring minimal paraphrasing
    25. UNK: Leave unchanged if error is unclear

    RULES:
    - Make the SMALLEST possible edit to fix each error
    - Change only what is grammatically or orthographically wrong
    - Preserve the original meaning and style
    - Do NOT improve fluency beyond fixing errors
    - If no errors exist, return the original sentence unchanged
    - Output plain text only: NEVER use Markdown or any markup in the output
    """

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
            Text: ok, pushed the fix 👍 can you rerun the tests?
            {"corrected":"ok, pushed the fix 👍 can you rerun the tests?","edits":[]}
            Text: The document has been reviewed by me and a small number of changes have been made.
            {"corrected":"I reviewed the doc and made a few changes.","edits":[]}
            Text: Great question — let's dive in! We're excited to leverage our robust new tool to seamlessly streamline your workflow.
            {"corrected":"Good question! Our new tool should make your work a lot easier.","edits":[]}
            Text: Thrilled to share that I've embarked on an exciting new chapter — truly grateful for this incredible journey!
            {"corrected":"Some news: I'm starting something new, and I'm really grateful.","edits":[]}
            """
        case (.rewrite, .formal):
            raw = """
            Text: hey can u send me the numbers asap, need them for the call
            {"corrected":"Hi, could you please send me the numbers as soon as possible? I need them for the call.","edits":[{"from":"hey can u send me the numbers asap, need them","to":"Hi, could you please send me the numbers as soon as possible? I need them","category":"tone","why":"Professional wording"}]}
            Text: Thank you for the update. I will review the draft tomorrow.
            {"corrected":"Thank you for the update. I will review the draft tomorrow.","edits":[]}
            Text: At this point in time, it was decided by the committee that the launch would be delayed due to the fact that testing is not finished.
            {"corrected":"The committee decided to delay the launch because testing is not finished.","edits":[]}
            Text: In today's fast-paced landscape, it's worth noting that our team has delved deep into the data — and the results are truly transformative.
            {"corrected":"Our team has studied the data closely, and the results are significant.","edits":[]}
            Text: Our solution empowers stakeholders to navigate the ever-evolving complexities of compliance — ensuring peace of mind at every step.
            {"corrected":"Our product helps teams keep up with changing compliance rules.","edits":[]}
            """
        case (.rewrite, .strictFormal):
            raw = """
            Text: Hi Tom, thanks! We can't make it Monday, can we do Tuesday?
            {"corrected":"Dear Tom, thank you. Unfortunately, we are unable to attend on Monday. Would Tuesday be convenient?","edits":[{"from":"Hi Tom, thanks! We can't make it Monday, can we do Tuesday?","to":"Dear Tom, thank you. Unfortunately, we are unable to attend on Monday. Would Tuesday be convenient?","category":"tone","why":"Strictly formal register"}]}
            Text: Dear Ms. Chen, thank you for your letter. We will send our response by Friday.
            {"corrected":"Dear Ms. Chen, thank you for your letter. We will send our response by Friday.","edits":[]}
            Text: just checking if the contract is signed yet, sorry to bug you
            {"corrected":"I would be grateful to know whether the contract has been signed.","edits":[]}
            Text: hey, any update on the invoice? need it for the audit
            {"corrected":"Could you please provide an update on the invoice? It is required for the audit.","edits":[]}
            Text: I hope this email finds you well! I wanted to reach out to underscore our commitment to fostering a seamless, synergistic partnership — one that truly moves the needle.
            {"corrected":"I am writing to confirm our commitment to a strong and effective partnership.","edits":[]}
            Text: It is important to note that this initiative represents a paradigm shift — a testament to our unwavering dedication to excellence.
            {"corrected":"This initiative is a significant change and reflects our commitment to quality.","edits":[]}
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
