import ApplicationServices
@testable import AureAccessibility
import AureCore
import AureInference
import Foundation
import Testing
@testable import AureUI

@MainActor private func testField(_ text: String, pid: Int32 = 42) -> FocusedField {
    FocusedField(element: AXElement(AXUIElementCreateApplication(pid)), pid: pid, bundleId: "test.app",
                 appName: "Test", role: "AXTextArea", text: text, selection: nil, frame: nil,
                 caretRect: nil, isWebArea: false)
}

@MainActor private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate(), "Timed out waiting for review")
}

@Test @MainActor func coordinatorPreviewsThenDismissesWithoutReplacing() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let input = "I would like to ask you to send the report."
    let fake = FakeLLMProvider { system, _ in
        system.contains("Task: rewrite") ? "Please send the report." : input
    }
    await app.correction.setProvider(fake)
    let c = CheckCoordinator(app: app, isReady: { true })
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    var writes = 0
    c.replaceText = { _, _, _ in writes += 1; return true }
    c.fieldChanged(testField(input))
    try await waitFor { c.writingSuggestion != nil }
    #expect(c.status == .suggestions(1))
    #expect(writes == 0)
    let suggestion = try #require(c.writingSuggestion)
    c.dismissWritingSuggestion()
    #expect(c.status == .clean)
    await c.applyWritingSuggestion(suggestion)
    #expect(writes == 0)
    c.runCheck()
    c.requestWritingSuggestion()
    #expect(fake.callCount == 2)
    #expect(c.writingSuggestion == nil)
    c.stop()
}

@Test @MainActor func settingsInvalidatePendingReview() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let input = "I would like to ask you to send the report."
    let fake = FakeLLMProvider { system, _ in
        system.contains("Task: rewrite") ? "Please send the report." : input
    }
    await app.correction.setProvider(fake)
    let c = CheckCoordinator(app: app, isReady: { true })
    app.coordinator = c
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    c.fieldChanged(testField(input))
    try await waitFor { c.writingSuggestion != nil }
    app.tone = .informal
    #expect(c.result == nil)
    #expect(c.writingSuggestion == nil)
    #expect(c.status == .hidden)
    c.stop()
}

@Test @MainActor func acceptingAlternativeWritesOnceAndRejectsDoubleClick() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let input = "I would like to ask you to send the report."
    await app.correction.setProvider(FakeLLMProvider { system, _ in
        system.contains("Task: rewrite") ? "Please send the report." : input
    })
    let c = CheckCoordinator(app: app, isReady: { true })
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    var writes: [String] = []
    c.replaceText = { field, range, replacement in
        #expect(field.text == input)
        #expect(range == 0..<input.utf16.count)
        writes.append(replacement)
        try? await Task.sleep(for: .milliseconds(100))
        return true
    }
    c.fieldChanged(testField(input))
    try await waitFor { c.writingSuggestion != nil }
    let suggestion = try #require(c.writingSuggestion)
    let first = Task { await c.applyWritingSuggestion(suggestion) }
    try await waitFor { writes.count == 1 }
    await c.applyWritingSuggestion(suggestion)
    await first.value
    #expect(writes == ["Please send the report."])
    #expect(c.writingSuggestion == nil)
    c.stop()
}

@Test @MainActor func mixedReviewKeepsGrammarSeparateAndDismissalCannotReintroduceFix() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let input = "I would like to say the reports is ready."
    let baseline = "I would like to say the reports are ready."
    let fake = FakeLLMProvider { system, user in
        if system.contains("Task: rewrite") {
            #expect(user.hasPrefix(baseline))
            return "The reports are ready."
        }
        return baseline
    }
    await app.correction.setProvider(fake)
    let c = CheckCoordinator(app: app, isReady: { true })
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    c.fieldChanged(testField(input))
    try await waitFor { c.writingSuggestion != nil }
    #expect(c.status == .issues(1))
    #expect(c.visibleIssues.count == 1)
    #expect(c.writingSuggestion?.original == baseline)
    c.dismiss(try #require(c.visibleIssues.first))
    #expect(c.visibleIssues.isEmpty)
    #expect(c.writingSuggestion == nil)
    c.requestWritingSuggestion(tone: .informal)
    #expect(!c.suggestingWriting)
    #expect(fake.callCount == 2)
    c.stop()
}

@Test @MainActor func staleAlternativeCannotApplyAfterFieldOrTextChanges() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let input = "I would like to ask you to send the report."
    await app.correction.setProvider(FakeLLMProvider { system, _ in
        system.contains("Task: rewrite") ? "Please send the report." : input
    })
    let c = CheckCoordinator(app: app, isReady: { true })
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    var writes = 0
    c.replaceText = { _, _, _ in writes += 1; return true }
    c.fieldChanged(testField(input))
    try await waitFor { c.writingSuggestion != nil }
    let suggestion = try #require(c.writingSuggestion)
    c.debounceInterval = .seconds(60)
    c.fieldChanged(testField(input, pid: 43)) // same text, different target
    #expect(c.result == nil)
    #expect(c.writingSuggestion == nil)
    await c.applyWritingSuggestion(suggestion)
    #expect(writes == 0)
    c.fieldChanged(testField(input + " And the summary.", pid: 43))
    await c.applyWritingSuggestion(suggestion)
    #expect(writes == 0)
    c.stop()
}

@Test @MainActor func failedWritingPassPreservesGrammarErrors() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await app.correction.setProvider(FakeLLMProvider { system, _ in
        if system.contains("Task: rewrite") { throw AureError.modelNotLoaded }
        return "The reports are ready."
    })
    let c = CheckCoordinator(app: app, isReady: { true })
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    c.fieldChanged(testField("The reports is ready."))
    try await waitFor { c.writingError != nil }
    #expect(c.status == .issues(1))
    #expect(c.visibleIssues.count == 1)
    #expect(c.writingSuggestion == nil)
    c.stop()
}

@Test @MainActor func applyingGrammarFixesDoesNotApplyOptionalAlternative() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let input = "I would like to say the reports is ready."
    let baseline = "I would like to say the reports are ready."
    await app.correction.setProvider(FakeLLMProvider { system, _ in
        system.contains("Task: rewrite") ? "The reports are ready." : baseline
    })
    let c = CheckCoordinator(app: app, isReady: { true })
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    var written: String?
    c.replaceText = { _, _, text in written = text; return true }
    c.fieldChanged(testField(input))
    try await waitFor { c.writingSuggestion != nil }
    await c.replaceAll()
    #expect(written == baseline)
    #expect(c.result == nil)
    #expect(c.writingSuggestion == nil)
    c.stop()
}

@Test @MainActor func lateWritingCompletionCannotRestoreStaleReview() async throws {
    let app = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let input = "I would like to ask you to send the report."
    let fake = FakeLLMProvider { system, _ in
        if system.contains("Task: rewrite") {
            try? await Task.sleep(for: .milliseconds(150))
            return "Please send the report."
        }
        return input
    }
    await app.correction.setProvider(fake)
    let c = CheckCoordinator(app: app, isReady: { true })
    c.debounceInterval = .zero
    c.writingDebounceInterval = .zero
    c.fieldChanged(testField(input))
    try await waitFor { fake.callCount == 2 }
    c.debounceInterval = .seconds(60)
    c.fieldChanged(testField(input + " New text."))
    try await Task.sleep(for: .milliseconds(200))
    #expect(c.result == nil)
    #expect(c.writingSuggestion == nil)
    #expect(c.status == .hidden)
    c.stop()
}

@Test @MainActor func reviewStatusPrioritizesErrorsOverOptionalWriting() {
    #expect(CheckCoordinator.Status.review(errors: 2, suggestions: 1) == .issues(2))
    #expect(CheckCoordinator.Status.review(errors: 0, suggestions: 1) == .suggestions(1))
    #expect(CheckCoordinator.Status.review(errors: 0, suggestions: 0) == .clean)
}

@Test @MainActor func writingSuggestionsAreModelGeneratedAndBounded() async throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let app = AppState(defaults: defaults)
    let provider = FakeLLMProvider(corrected: "Please send the report.")
    await app.correction.setProvider(provider)
    let input = "I would like to ask you to send the report."
    let suggestion = try await app.suggestWriting(input)
    #expect(suggestion?.replacement == "Please send the report.")
    #expect(provider.callCount == 1)
    _ = try await app.suggestWriting(input)
    #expect(provider.callCount == 1) // reuse CorrectionService's request cache
    let long = try await app.suggestWriting(String(repeating: "word ", count: 500))
    #expect(long == nil)
    #expect(provider.callCount == 1)
    app.writingSuggestionsEnabled = false
    let disabled = try await app.suggestWriting("Could you send me the document?")
    #expect(disabled == nil)
    #expect(provider.callCount == 1)
}
