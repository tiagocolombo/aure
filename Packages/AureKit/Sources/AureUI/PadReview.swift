import AppKit
import AureCore
import Foundation

/// One underlined span in Aure Pad: a needed fix (red) or an optional
/// better-writing alternative (yellow).
struct PadAnnotation: Identifiable, Equatable {
    enum Kind { case issue, suggestion }

    var issue: Issue
    var kind: Kind

    var id: UUID { issue.id }

    static let issueColor = NSColor.systemRed
    /// Darker than system yellow in light mode, where yellow dots on white are hard to see.
    static let suggestionColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow : NSColor(srgbRed: 0.80, green: 0.60, blue: 0, alpha: 1)
    }

    var color: NSColor { kind == .issue ? Self.issueColor : Self.suggestionColor }
}

/// The review shown in Aure Pad: checker results plus the optional writing
/// alternative, kept at the right offsets while the text changes.
struct PadReview: Equatable {
    var result: CheckResult
    /// Hunks of the optional writing alternative, as offsets into the current text.
    var writing: [Issue] = []
    var writingTone: Tone?
    var writingSoundsAIWritten = false
    /// One writing alternative per check: accepting its last change must not ask for another.
    var writingRequested = false
    var dismissed: Set<UUID> = []

    init(result: CheckResult) {
        self.result = result
    }

    var text: String { result.request.text }

    /// After a rewrite every change is optional, so it reads as a suggestion.
    var isRewrite: Bool { result.request.mode == .rewrite }

    var visibleIssues: [Issue] { result.issues.filter { !dismissed.contains($0.id) } }
    var visibleWriting: [Issue] { writing.filter { !dismissed.contains($0.id) } }

    var annotations: [PadAnnotation] {
        visibleIssues.map { PadAnnotation(issue: $0, kind: isRewrite ? .suggestion : .issue) }
            + visibleWriting.map { PadAnnotation(issue: $0, kind: .suggestion) }
    }

    /// The text with every visible checker change applied.
    var corrected: String { CorrectionServiceBridge.apply(visibleIssues, to: text) }

    /// Like the menu bar bubble: ask for a writing alternative only once no
    /// corrections remain and none were dismissed (a rewrite must not quietly
    /// reintroduce a dismissed fix).
    var wantsWritingSuggestion: Bool {
        !isRewrite && !writingRequested && visibleIssues.isEmpty && dismissed.isEmpty
    }

    /// The user typed: move underlines after the edit, drop the ones it touched.
    mutating func textChanged(to new: String) {
        guard new != text else { return }
        let edit = TextEdit(from: text, to: new)
        result.issues = edit.shift(result.issues)
        writing = edit.shift(writing)
        result.request.text = new
    }

    /// Applies one underlined change and returns the new text.
    @discardableResult
    mutating func apply(_ id: UUID) -> String {
        guard let issue = (result.issues + writing).first(where: { $0.id == id }) else { return text }
        let edit = TextEdit(range: issue.range, replacementLength: issue.replacement.utf16.count)
        let new = CorrectionServiceBridge.apply([issue], to: text)
        result.issues = edit.shift(result.issues.filter { $0.id != id }, keepingAdjacent: true)
        writing = edit.shift(writing.filter { $0.id != id }, keepingAdjacent: true)
        result.request.text = new
        return new
    }

    mutating func dismiss(_ id: UUID) {
        dismissed.insert(id)
    }

    /// Shows the alternative's changes as yellow underlines. Ignored when it was
    /// written for a different text.
    mutating func setWriting(_ suggestion: WritingSuggestion) {
        guard suggestion.original == text else { return }
        let explanation = suggestion.soundsAIWritten
            ? "Plainer \(suggestion.tone.displayName.lowercased()) wording"
            : "\(suggestion.tone.displayName) alternative"
        writing = IssueBuilder.issues(original: suggestion.original, corrected: suggestion.replacement, edits: [])
            .map { issue in
                var issue = issue
                issue.category = .tone
                issue.explanation = explanation
                return issue
            }
        writingTone = suggestion.tone
        writingSoundsAIWritten = suggestion.soundsAIWritten
    }
}

/// The single replacement that turns one text into another, in UTF-16 offsets:
/// `range` in the old text was replaced by `replacementLength` units.
struct TextEdit: Equatable {
    var range: Range<Int>
    var replacementLength: Int

    init(range: Range<Int>, replacementLength: Int) {
        self.range = range
        self.replacementLength = replacementLength
    }

    init(from old: String, to new: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        range = prefix..<(a.count - suffix)
        replacementLength = b.count - prefix - suffix
    }

    /// Issues before the edit stay, issues after it move with it, and issues it
    /// overlaps are dropped. Typing right next to an issue changes its word, so
    /// touching issues are dropped too unless `keepingAdjacent`.
    func shift(_ issues: [Issue], keepingAdjacent: Bool = false) -> [Issue] {
        let delta = replacementLength - range.count
        return issues.compactMap { issue in
            let before = keepingAdjacent ? issue.range.upperBound <= range.lowerBound
                : issue.range.upperBound < range.lowerBound
            let after = keepingAdjacent ? issue.range.lowerBound >= range.upperBound
                : issue.range.lowerBound > range.upperBound
            if before { return issue }
            guard after else { return nil }
            var issue = issue
            issue.range = (issue.range.lowerBound + delta)..<(issue.range.upperBound + delta)
            return issue
        }
    }
}

extension Issue {
    /// The UTF-16 range to underline. A pure insertion has no characters of its
    /// own, so it underlines the word before it (or after it, at the start).
    func underlineRange(in text: String) -> Range<Int>? {
        let units = Array(text.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
        if !range.isEmpty { return range }
        func isSpace(_ i: Int) -> Bool {
            Unicode.Scalar(units[i]).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var end = range.lowerBound
        while end > 0, isSpace(end - 1) { end -= 1 }
        var start = end
        while start > 0, !isSpace(start - 1) { start -= 1 }
        if start < end { return start..<end }
        var s = range.lowerBound
        while s < units.count, isSpace(s) { s += 1 }
        var e = s
        while e < units.count, !isSpace(e) { e += 1 }
        return s < e ? s..<e : nil
    }
}
