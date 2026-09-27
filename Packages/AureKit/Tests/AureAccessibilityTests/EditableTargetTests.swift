import Testing
@testable import AureAccessibility

@Test func resolvesExplicitEditableAncestorRatherThanPartialFocusedLeaf() {
    let result = EditableTarget.read(1, isSecure: { _ in false }, ancestor: { _ in 2 },
                                     read: { $0 == 2 ? "complete" : "partial" })
    #expect(result == "complete")
}

@Test func neverReadsSecureFocusedOrAncestorElements() {
    for secure in [1, 2] {
        let result: String? = EditableTarget.read(1, isSecure: { $0 == secure }, ancestor: { _ in 2 },
                                                  read: { _ in Issue.record("secure read"); return "secret" })
        #expect(result == nil)
    }
}

@Test func unreadableAncestorDoesNotFallBackToPartialLeaf() {
    let result = EditableTarget.read(1, isSecure: { _ in false }, ancestor: { _ in 2 },
                                     read: { $0 == 1 ? "partial" : nil })
    #expect(result == nil)
}
