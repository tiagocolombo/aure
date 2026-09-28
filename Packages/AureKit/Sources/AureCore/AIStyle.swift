import Foundation

/// "Does this read like generic AI-generated writing?" A separate one-token
/// yes/no question: small models judge this far more reliably on its own than
/// as a side task of a rewrite. The model decides; nothing here matches words.
public enum AIStyleCheck {
    /// Dashes the rewrite may not generate. `LlamaServerProvider` bans only
    /// strings that are a single token, so no shared byte tokens are affected.
    public static let bannedDashes = ["\u{2014}", " \u{2014}", " \u{2013}"]

    public static func prompt(for text: String, disableThinking: Bool = true) -> Prompt {
        let system = """
        You judge writing style. Answer with one word: yes or no.
        Answer yes when the user's text reads like generic AI-generated writing: buzzwords and \
        corporate jargon, hype, vague grand claims, stock filler phrases ("In today's fast-paced \
        world", "I hope this finds you well") or em dashes used for drama.
        Answer no for plain, specific writing by a person, even when it is casual, rough or has typos.
        """
        let suffix = disableThinking ? "\n/no_think" : ""
        let examples: [(String, String)] = [
            ("Great question — let's dive in! We're excited to leverage our robust platform to seamlessly streamline your workflow.", "yes"),
            ("can you send the invoice by friday? accounting needs it before the audit", "no"),
            ("It is important to note that this initiative represents a paradigm shift — a testament to our unwavering dedication to excellence.", "yes"),
            ("Thanks for the notes. I fixed the chart on page 3 and moved the budget table to the appendix.", "no"),
        ]
        return Prompt(system: system,
                      examples: examples.map { Prompt.Turn(user: $0.0 + suffix, assistant: $0.1) },
                      user: text + suffix,
                      temperature: 0,
                      maxTokens: 2)
    }

    /// Reads the answer from the first token's alternatives when available
    /// (P(yes) vs P(no)); otherwise from the answer text.
    public static func isAIStyle(answer: String, tokens: [TokenLogprob]) -> Bool {
        if let first = tokens.first {
            var yes = 0.0, no = 0.0
            for alt in first.top + [TokenLogprob.Alternative(bytes: first.bytes, logprob: first.logprob)] {
                switch String(decoding: alt.bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased() {
                case "yes": yes = max(yes, exp(alt.logprob))
                case "no": no = max(no, exp(alt.logprob))
                default: break
                }
            }
            if yes > 0 || no > 0 { return yes > no }
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("yes")
    }
}
