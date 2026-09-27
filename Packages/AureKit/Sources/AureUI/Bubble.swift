import AppKit
import AureAccessibility
import AureCore
import SwiftUI

/// Floating non-activating panel that never steals focus from the app you
/// are typing in.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
    }

    // Never take keyboard focus: the app you type in must stay key so the
    // replacement (AX or ⌘V) lands in its text field.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts the very first click even though its panel is
/// not key and Aure is not the active app (otherwise the click only focuses
/// the panel and is swallowed).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The bubble's view: handles the click in AppKit directly, which is reliable
/// in a non-activating panel over Chrome/Slack.
final class BubbleHostView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        Log.info("bubble: mouseDown")
        onClick?()
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Owns the bubble and the suggestion card, and positions them next to the
/// focused field.
@MainActor
final class BubbleController {
    private let coordinator: CheckCoordinator
    private let app: AppState
    private let bubble = FloatingPanel(size: NSSize(width: 26, height: 26))
    private let card = FloatingPanel(size: NSSize(width: 380, height: 300))
    private var cardVisible = false
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    static let cardWidth: CGFloat = 380

    init(coordinator: CheckCoordinator, app: AppState) {
        self.coordinator = coordinator
        self.app = app
        let bubbleHost = BubbleHostView(rootView: AnyView(BubbleView().environment(coordinator)))
        bubbleHost.onClick = { [weak self] in self?.toggleCard() }
        bubble.contentView = bubbleHost
        let host = FirstClickHostingView(rootView: AnyView(SuggestionCard(close: { [weak self] in self?.hideCard() })
            .environment(coordinator).environment(app)))
        card.contentView = host
        coordinator.onUpdate = { [weak self] in self?.update() }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.hideCard() } } // Esc
        }
        // Clicking anywhere else (outside the bubble and card) closes the card.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cardVisible else { return }
                let p = NSEvent.mouseLocation
                if !self.card.frame.contains(p), !self.bubble.frame.contains(p) { self.hideCard() }
            }
        }
    }

    func update() {
        guard coordinator.status != .hidden, let f = coordinator.field, let anchor = anchorRect(f) else {
            // While the card is open, keep it (and the bubble) where they are;
            // clicking the card can briefly blur the field in web apps.
            if !cardVisible { bubble.orderOut(nil) }
            return
        }
        // Bottom-right inside the field (like Grammarly), clamped to screen.
        let size = bubble.frame.size
        var origin = NSPoint(x: anchor.maxX - size.width - 6, y: anchor.minY + 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            origin.y = min(max(origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
        }
        if bubble.frame.origin != origin { bubble.setFrameOrigin(origin) }
        if !bubble.isVisible { bubble.orderFrontRegardless() }
        if cardVisible { positionCard() }
    }

    /// Field frame; for huge web areas use the caret line instead.
    private func anchorRect(_ f: FocusedField) -> CGRect? {
        if let frame = f.frame, frame.height < 600, frame.width > 40 { return frame }
        if let caret = f.caretRect {
            return CGRect(x: caret.minX, y: caret.minY - 4, width: max(caret.width, 220), height: caret.height + 8)
        }
        return f.frame
    }

    func toggleCard() { cardVisible ? hideCard() : showCard() }

    func showCard() {
        if coordinator.result == nil { coordinator.runCheck() }
        cardVisible = true
        positionCard()
        card.orderFrontRegardless()
        Log.info("card: shown at \(card.frame) status=\(coordinator.status)")
    }

    func hideCard() {
        guard cardVisible else { return }
        cardVisible = false
        card.orderOut(nil)
        Log.info("card: hidden")
    }

    private func positionCard() {
        let b = bubble.frame
        guard let host = card.contentView else { return }
        // Measure the SwiftUI content at the fixed width.
        host.frame.size.width = Self.cardWidth
        host.layoutSubtreeIfNeeded()
        var height = host.fittingSize.height
        if height < 60 || height > 700 { height = 320 }
        let size = NSSize(width: Self.cardWidth, height: height)
        var origin = NSPoint(x: b.maxX - size.width, y: b.maxY + 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(b) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            if origin.y + size.height > vf.maxY { origin.y = b.minY - size.height - 6 }
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            origin.y = max(origin.y, vf.minY + 4)
        }
        card.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// The small red/green circle.
struct BubbleView: View {
    @Environment(CheckCoordinator.self) private var c
    @State private var hover = false

    var body: some View {
        ZStack {
            Circle().fill(fill).shadow(radius: 1.5, y: 0.5)
            content
        }
        .frame(width: 22, height: 22)
        .scaleEffect(hover ? 1.12 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .onHover { hover = $0 }
        .help(help)
    }

    @ViewBuilder var content: some View {
        switch c.status {
        case .checking:
            ProgressView().controlSize(.mini).tint(.white)
        case .suggestions(let n):
            Text("\(min(n, 99))").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
        case .issues(let n):
            Text("\(min(n, 99))").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
        case .clean:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        case .error:
            Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        case .hidden:
            EmptyView()
        }
    }

    var fill: Color {
        switch c.status {
        case .issues: Color(red: 0.89, green: 0.23, blue: 0.23)
        case .suggestions: Color.yellow
        case .clean: Color(red: 0.16, green: 0.68, blue: 0.38)
        case .checking: Color.gray
        case .error: Color.orange
        case .hidden: .clear
        }
    }

    var help: String {
        switch c.status {
        case .issues(let n): "Aure found \(n) error\(n == 1 ? "" : "s"). Click to review."
        case .suggestions(let n): "Aure: \(n) optional writing suggestion\(n == 1 ? "" : "s"). Click to review."
        case .clean: "Aure: looks good"
        case .checking: "Aure is checking…"
        case .error(let e): "Aure: \(e)"
        case .hidden: ""
        }
    }
}

/// Card with the corrected text, per-issue list and actions.
struct SuggestionCard: View {
    @Environment(CheckCoordinator.self) private var c
    @Environment(AppState.self) private var app
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AureLogo(size: 20)
                Text(title).font(.headline)
                Spacer()
                Menu {
                    ForEach(Tone.allCases) { t in
                        Button("Preview as \(t.displayName)") { Task { await c.rewrite(tone: t) } }
                    }
                } label: { Image(systemName: "wand.and.stars") }
                    .menuStyle(.borderlessButton).fixedSize().help("Rewrite in a tone")
                    .disabled(c.result == nil || c.suggestingWriting || !app.writingSuggestionsEnabled || !c.dismissed.isEmpty)
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close (Esc)")
            }

            switch c.status {
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
            case .error(let e):
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            default:
                if let r = c.result {
                    if c.visibleIssues.isEmpty {
                        Label("No grammar errors found.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Grammar & spelling").font(.subheadline.bold()).foregroundStyle(.red)
                        ScrollView {
                            DiffText(original: r.request.text, issues: c.visibleIssues)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(c.visibleIssues) { issue in
                                    IssueRow(issue: issue,
                                             onAccept: { close(); Task { await c.apply(issue) } },
                                             onDismiss: { c.dismiss(issue) })
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                        HStack {
                            Text("Tone: \(app.tone.displayName)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(corrected(r), forType: .string)
                            }
                            Button("Apply fixes") { close(); Task { await c.replaceAll() } }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    writingSection
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    @ViewBuilder var writingSection: some View {
        if let suggestion = c.writingSuggestion {
            Divider()
            Label("Better writing · Optional", systemImage: "sparkles").font(.subheadline.bold())
                .foregroundStyle(.orange)
            Text("\(suggestion.tone.displayName) alternative. Review before applying.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                DiffText(original: suggestion.original,
                         issues: IssueBuilder.issues(original: suggestion.original, corrected: suggestion.replacement, edits: []))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 110)
            if c.result?.hasIssues == true {
                Text("Applying this alternative also includes the grammar fixes above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Dismiss") { c.dismissWritingSuggestion() }
                Spacer()
                Button("Apply alternative") { close(); Task { await c.applyWritingSuggestion(suggestion) } }
            }
        } else if c.suggestingWriting {
            HStack { ProgressView().controlSize(.mini); Text("Looking for an optional improvement…").font(.caption) }
        } else if let error = c.writingError {
            Text(error).font(.caption).foregroundStyle(.secondary)
        }
    }

    var title: String {
        switch c.status {
        case .issues(let n): "\(n) error\(n == 1 ? "" : "s")"
        case .suggestions: "Writing suggestion"
        case .clean: "Looks good"
        case .checking: "Checking"
        default: "Aure"
        }
    }

    func corrected(_ r: CheckResult) -> String {
        DiffEngine.apply(c.visibleIssues.map { .init(range: $0.range, original: $0.original, replacement: $0.replacement) },
                         to: r.request.text)
    }
}
