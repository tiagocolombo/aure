import Foundation

/// A model-generated, optional alternative, kept separate from necessary fixes.
/// `original` is the grammar-corrected baseline, not a second set of field offsets.
public struct WritingSuggestion: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let original: String
    public let replacement: String
    public let tone: Tone

    public init?(original: String, replacement: String, tone: Tone) {
        // Presentation filtering only, never a grammar or rewrite rule engine.
        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              words(original) != words(replacement) else { return nil }
        self.original = original
        self.replacement = replacement
        self.tone = tone
    }
}
