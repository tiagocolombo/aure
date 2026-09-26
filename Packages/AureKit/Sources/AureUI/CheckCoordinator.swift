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
        case error(String)
    }

    public private(set) var status: Status = .hidden
    public private(set) var activity: TrackerActivity = .noPermission
    public private(set) var field: FocusedField?
    public private(set) var result: CheckResult?
    /// UTF-16 offset of the checked slice inside the field text.
    public private(set) var sliceOffset = 0
    public var dismissed = Set<String>()

    @ObservationIgnored private let tracker = FocusTracker()
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored public var onUpdate: (() -> Void)?
    public var debounceInterval: Duration = .milliseconds(700)

    public init(app: AppState) {
        self.app = app
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

    public func stop() { tracker.stop() }

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
            case .error(let e):
                return ("Couldn't check \(name)", e, "exclamationmark.triangle.fill", .orange)
            }
        }
    }

    public enum SummaryColor { case gray, green, red, orange }

    public var visibleIssues: [Issue] {
        (result?.issues ?? []).filter { !dismissed.contains(Self.key($0)) }
    }

    static func key(_ i: Issue) -> String { "\(i.original)→\(i.replacement)" }

    private func fieldChanged(_ f: FocusedField?) {
        let textChanged = f?.text != field?.text || f?.element != field?.element
        field = f
        guard let app, let f, !app.paused, app.engine.isReady, CheckScope.isWorthChecking(f.text) else {
            debounce?.cancel()
            running?.cancel()
            result = nil
            status = .hidden
            onUpdate?()
            return
        }
        if !textChanged {
            onUpdate?() // position only
            return
        }
        // Keep showing the last state while typing, but mark stale results.
        if let r = result, !f.text.contains(r.request.text) { result = nil }
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
        guard let app, let f = field else { return }
        let slice = CheckScope.slice(of: f.text, caret: f.selection?.lowerBound)
        running?.cancel()
        status = .checking
        onUpdate?()
        running = Task { [weak self] in
            do {
                let r = try await app.check(slice.text)
                guard let self, !Task.isCancelled, self.field?.text == f.text else { return }
                self.sliceOffset = slice.range.lowerBound
                self.result = r
                let n = self.visibleIssues.count
                self.status = n == 0 ? .clean : .issues(n)
            } catch AureError.cancelled {
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.status = .error(error.localizedDescription)
            }
            self?.onUpdate?()
        }
    }

    public func dismiss(_ issue: Issue) {
        dismissed.insert(Self.key(issue))
        let n = visibleIssues.count
        status = n == 0 ? .clean : .issues(n)
        onUpdate?()
    }

    /// Applies all visible suggestions to the field.
    public func replaceAll() async {
        guard let f = field, let r = result else { return }
        let slice = r.request.text
        let fixed = DiffEngine.apply(visibleIssues.map { .init(range: $0.range, original: $0.original, replacement: $0.replacement) },
                                     to: slice)
        let range = sliceOffset..<(sliceOffset + (slice as NSString).length)
        await TextReplacer.replace(in: f, range: range, with: fixed)
        afterReplace()
    }

    /// Applies one suggestion.
    public func apply(_ issue: Issue) async {
        guard let f = field else { return }
        let range = (issue.range.lowerBound + sliceOffset)..<(issue.range.upperBound + sliceOffset)
        await TextReplacer.replace(in: f, range: range, with: issue.replacement)
        afterReplace()
    }

    /// Rewrites the checked text in a tone and replaces it.
    public func rewrite(tone: Tone) async {
        guard let app, let f = field, let r = result else { return }
        status = .checking
        onUpdate?()
        do {
            let rw = try await app.check(r.request.text, mode: .rewrite, tone: tone)
            let range = sliceOffset..<(sliceOffset + (r.request.text as NSString).length)
            await TextReplacer.replace(in: f, range: range, with: rw.corrected)
            afterReplace()
        } catch {
            status = .error(error.localizedDescription)
            onUpdate?()
        }
    }

    private func afterReplace() {
        result = nil
        status = .checking
        onUpdate?()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.tracker.refresh()
        }
    }
}
