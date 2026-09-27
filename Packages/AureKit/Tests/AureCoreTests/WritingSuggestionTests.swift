import Testing
@testable import AureCore

@Test func rewritePromptAllowsNoImprovement() {
    let prompt = PromptBuilder.build(CheckRequest(text: "Please send the report.", tone: .formal, mode: .rewrite))
    #expect(prompt.system.contains("If the text is already clear"))
    #expect(prompt.system.contains("Never add facts"))
    #expect(prompt.examples.contains { $0.assistant + "\n/no_think" == $0.user })
    #expect(prompt.system.contains("repeat it exactly"))
}

@Test func writingSuggestionRejectsCosmeticOrUnchangedRewrites() {
    #expect(WritingSuggestion(original: "Please send the report.", replacement: "Please send the report.", tone: .formal) == nil)
    #expect(WritingSuggestion(original: "Please send the report.", replacement: "  please  send the report!\n", tone: .formal) == nil)
    #expect(WritingSuggestion(original: "Please send the report.", replacement: "", tone: .formal) == nil)
    let suggestion = WritingSuggestion(original: "I would like to ask you to send the report.", replacement: "Please send the report.", tone: .formal)
    #expect(suggestion?.replacement == "Please send the report.")
}
