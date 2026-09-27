import AureAccessibility
import AureCore
import Foundation
import Observation

/// Watches the focused field, debounces typing, runs checks and holds the
/// state the bubble and card render.
@MainActor
@Observable
public final class CheckCoordinator {
    public enum Status: Equatable {
        case hidden
        case checking
        case clean
        case issues(Int)
        case suggestions(Int)

        static func review(errors: Int, suggestions: Int) -> Status {
            if errors > 0 { return .issues(errors) }
            return suggestions > 0 ? .suggestions(suggestions) : .clean
        }
        case error(String)
    }

    public private(set) var status: Status = .hidden
    public private(set) var activity: TrackerActivity = .noPermission
    public private(set) var field: FocusedField?
    public private(set) var result: CheckResult?
    public private(set) var writingSuggestion: WritingSuggestion?
    public private(set) var suggestingWriting = false
    public private(set) var writingError: String?
    public private(set) var applying = false
    @ObservationIgnored private var checkedField: FocusedField?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var writingTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedWriting = false
    /// UTF-16 offset of the checked slice inside the field text.
    public private(set) var sliceOffset = 0
    public var dismissed = Set<String>()

    @ObservationIgnored private let tracker = FocusTracker()
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored public var onUpdate: (() -> Void)?
    public var debounceInterval: Duration = .milliseconds(700)
    var writingDebounceInterval: Duration = .seconds(1.2)
    @ObservationIgnored private let isReady: @MainActor () -> Bool
    @ObservationIgnored var replaceText: @MainActor (FocusedField, Range<Int>, String) async -> Bool = { field, range, text in
        await TextReplacer.replace(in: field, range: range, with: text) != nil
    }

    public convenience init(app: AppState) {
        self.init(app: app, isReady: { [weak app] in app?.engine.isReady == true })
    }

    init(app: AppState, isReady: @escaping @MainActor () -> Bool) {
        self.app = app
        self.isReady = isReady
        tracker.onChange = { [weak self] f in self?.fieldChanged(f) }
        tracker.onActivity = { [weak self] a in self?.activity = a }
    }

    public func start() {
        tracker.start()
        // The tracker ignores apps until Accessibility is granted; poll so we
        // start as soon as the user allows it, even with no settings window open.
        Task { [weak self] in
            var trusted = AccessibilityPermission.isTrusted
            while !Task.isCancelled, !trusted {
                try? await Task.sleep(for: .seconds(2))
                trusted = AccessibilityPermission.isTrusted
                if trusted {
                    self?.app?.accessibilityTrusted = true
                    self?.restart()
                }
            }
        }
    }

    public func stop() { tracker.stop(); invalidateReview() }

    public func restart() {
        tracker.stop()
        tracker.start()
    }

    /// One line for the menu bar: what Aure is doing right now.
    public var summary: (text: String, detail: String, symbol: String, color: SummaryColor) {
        guard let app else { return ("", "", "circle", .gray) }
        if app.paused { return ("Paused", "Turn off Pause to check your writing again.", "pause.circle.fill", .gray) }
        if !app.engine.isReady { return ("Model not ready", app.engine.label, "hourglass", .gray) }
        switch activity {
        case .noPermission:
            return ("Not allowed to read other apps", "Grant Accessibility below so Aure can check what you type.", "hand.raised.fill", .orange)
        case .blocked(let name):
            return ("Not checking \(name)", "Aure never reads terminals, code editors or password managers.", "eye.slash", .gray)
        case .noTextField(let name):
            return ("Waiting in \(name)", "Click into a message or email box and start typing.", "text.cursor", .gray)
        case .field(let name):
            switch status {
            case .hidden:
                return ("Watching \(name)", "Type at least a few words; the bubble appears in the corner of the box.", "eye", .gray)
            case .checking:
                return ("Checking your text in \(name)…", "", "ellipsis.circle", .gray)
            case .clean:
                return ("No issues in \(name)", "The green bubble in the text box means it looks good.", "checkmark.circle.fill", .green)
            case .issues(let n):
                return ("\(n) suggestion\(n == 1 ? "" : "s") in \(name)", "Click the red bubble in the text box to review and replace.", "exclamationmark.circle.fill", .red)
            case .suggestions(let n):
                return ("\(n) writing suggestion\(n == 1 ? "" : "s") in \(name)", "Click the yellow bubble to review optional improvements.", "sparkles", .orange)
            case .error(let e):
                return ("Couldn't check \(name)", e, "exclamationmark.triangle.fill", .orange)
            }
        }
    }

    public enum SummaryColor { case gray, green, red, orange }

    public var visibleIssues: [Issue] {
        (result?.issues ?? []).filter { !dismissed.contains(Self.key($0)) }
    }

    static func key(_ i: Issue) -> String { "\(i.range):\(i.original)→\(i.replacement)" }

    private func updateReviewStatus() {
        status = .review(errors: visibleIssues.count, suggestions: writingSuggestion == nil ? 0 : 1)
    }

    /// Discard every offset/candidate as soon as text, field or settings change.
    public func invalidateReview() {
        generation = UUID()
        debounce?.cancel()
        running?.cancel()
        writingTask?.cancel()
        result = nil
        checkedField = nil
        writingSuggestion = nil
        suggestingWriting = false
        writingError = nil
        attemptedWriting = false
        dismissed = []
        status = .hidden
        onUpdate?()
    }

    func fieldChanged(_ f: FocusedField?) {
        let textChanged = f?.text != field?.text || f?.element != field?.element
        if textChanged { invalidateReview() }
        field = f
        guard let app, let f, !app.paused, isReady(), CheckScope.isWorthChecking(f.text) else {
            invalidateReview()
            return
        }
        if !textChanged {
            onUpdate?() // position only
            return
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.runCheck()
        }
        onUpdate?()
    }

    /// Checks the current field now.
    public func runCheck() {
        guard let app, let f = field, !app.paused, isReady() else { return }
        if result != nil || status == .checking { return }
        let token = generation
        let slice = CheckScope.slice(of: f.text, caret: f.selection?.lowerBound)
        running?.cancel()
        status = .checking
        onUpdate?()
        running = Task { [weak self] in
            do {
                let r = try await app.check(slice.text)
                guard let self, !Task.isCancelled, self.generation == token, self.field?.element == f.element, self.field?.text == f.text else { return }
                self.sliceOffset = slice.range.lowerBound
                self.result = r
                self.checkedField = f
                self.updateReviewStatus()
                self.requestWritingSuggestion()
            } catch AureError.cancelled {
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.status = .error(error.localizedDescription)
            }
            self?.onUpdate?()
        }
    }

    public func dismiss(_ issue: Issue) {
        guard visibleIssues.contains(issue) else { return }
        dismissed.insert(Self.key(issue))
        // A rewrite based on a dismissed correction must not quietly reintroduce it.
        writingTask?.cancel()
        writingSuggestion = nil
        suggestingWriting = false
        updateReviewStatus()
        onUpdate?()
    }

    /// One delayed background request per unchanged review, or an explicit tone
    /// preview. Grammar remains visible while this lower-priority pass runs.
    public func requestWritingSuggestion(tone: Tone? = nil) {
        guard let app, app.writingSuggestionsEnabled, let r = result,
              checkedField != nil, dismissed.isEmpty, !suggestingWriting,
              tone != nil || !attemptedWriting else { return }
        attemptedWriting = true
        guard r.corrected.utf16.count <= 1200 else { return }
        let token = generation
        writingSuggestion = nil
        suggestingWriting = true
        writingError = nil
        updateReviewStatus()
        onUpdate?()
        writingTask = Task { [weak self] in
            do {
                if tone == nil { try await Task.sleep(for: self?.writingDebounceInterval ?? .seconds(1.2)) }
                try Task.checkCancellation()
                let suggestion = try await app.suggestWriting(r.corrected, tone: tone)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.writingSuggestion = suggestion
                self.suggestingWriting = false
                self.updateReviewStatus()
                self.onUpdate?()
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.suggestingWriting = false
                self.writingError = "Optional writing suggestion unavailable. Grammar results are still shown."
                self.updateReviewStatus()
                self.onUpdate?()
            }
        }
    }

    public func dismissWritingSuggestion() {
        writingSuggestion = nil
        updateReviewStatus()
        onUpdate?()
    }

    private var currentCheckedField: FocusedField? {
        guard !applying, let app, !app.paused, isReady(), let f = field, let checkedField,
              f.element == checkedField.element, f.text == checkedField.text else { return nil }
        return f
    }

    public func applyWritingSuggestion(_ suggestion: WritingSuggestion) async {
        guard writingSuggestion == suggestion, let f = currentCheckedField, let r = result else { return }
        let range = sliceOffset..<(sliceOffset + r.request.text.utf16.count)
        let token = generation
        writingTask?.cancel()
        applying = true
        defer { applying = false }
        let succeeded = await replaceText(f, range, suggestion.replacement)
        guard generation == token else { return }
        finishReplacement(succeeded: succeeded)
    }

    /// Applies visible grammar fixes only, never optional writing changes.
    public func replaceAll() async {
        guard let f = currentCheckedField, let r = result, !visibleIssues.isEmpty else { return }
        let slice = r.request.text
        let fixed = DiffEngine.apply(visibleIssues.map { .init(range: $0.range, original: $0.original, replacement: $0.replacement) },
                                     to: slice)
        let range = sliceOffset..<(sliceOffset + (slice as NSString).length)
        let token = generation
        writingTask?.cancel()
        applying = true
        defer { applying = false }
        let succeeded = await replaceText(f, range, fixed)
        guard generation == token else { return }
        finishReplacement(succeeded: succeeded)
    }

    /// Applies one suggestion.
    public func apply(_ issue: Issue) async {
        guard let f = currentCheckedField, visibleIssues.contains(issue) else { return }
        let range = (issue.range.lowerBound + sliceOffset)..<(issue.range.upperBound + sliceOffset)
        let token = generation
        writingTask?.cancel()
        applying = true
        defer { applying = false }
        let succeeded = await replaceText(f, range, issue.replacement)
        guard generation == token else { return }
        finishReplacement(succeeded: succeeded)
    }

    /// Tone actions preview an alternative; only Apply writes to the field.
    public func rewrite(tone: Tone) async {
        requestWritingSuggestion(tone: tone)
    }

    private func finishReplacement(succeeded: Bool) {
        if succeeded { afterReplace() }
        else {
            invalidateReview()
            status = .error("Text changed or replacement could not be verified. Check again.")
            onUpdate?()
        }
    }

    private func afterReplace() {
        invalidateReview()
        status = .hidden
        onUpdate?()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.tracker.refresh()
            self?.runCheck()
        }
    }
}
