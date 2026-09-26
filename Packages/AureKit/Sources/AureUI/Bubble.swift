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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

    init(coordinator: CheckCoordinator, app: AppState) {
        self.coordinator = coordinator
        self.app = app
        bubble.contentView = NSHostingView(rootView: BubbleView(onTap: { [weak self] in self?.toggleCard() })
            .environment(coordinator))
        let host = NSHostingView(rootView: SuggestionCard(close: { [weak self] in self?.hideCard() })
            .environment(coordinator).environment(app))
        host.sizingOptions = [.preferredContentSize]
        card.contentView = host
        coordinator.onUpdate = { [weak self] in self?.update() }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.hideCard() } } // Esc
        }
    }

    func update() {
        guard coordinator.status != .hidden, let f = coordinator.field, let anchor = anchorRect(f) else {
            bubble.orderOut(nil)
            hideCard()
            return
        }
        // Bottom-right inside the field (like Grammarly), clamped to screen.
        let size = bubble.frame.size
        var origin = NSPoint(x: anchor.maxX - size.width - 6, y: anchor.minY + 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            origin.y = min(max(origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
        }
        bubble.setFrameOrigin(origin)
        bubble.orderFrontRegardless()
        if cardVisible { positionCard() }
        if coordinator.status == .clean || coordinator.status == .hidden, cardVisible, coordinator.visibleIssues.isEmpty,
           coordinator.result == nil {
            hideCard()
        }
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
    }

    func hideCard() {
        cardVisible = false
        card.orderOut(nil)
    }

    private func positionCard() {
        let b = bubble.frame
        card.contentView?.layoutSubtreeIfNeeded()
        let size = card.contentView?.fittingSize ?? card.frame.size
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
    let onTap: () -> Void
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
        .onTapGesture(perform: onTap)
        .help(help)
    }

    @ViewBuilder var content: some View {
        switch c.status {
        case .checking:
            ProgressView().controlSize(.mini).tint(.white)
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
        case .clean: Color(red: 0.16, green: 0.68, blue: 0.38)
        case .checking: Color.gray
        case .error: Color.orange
        case .hidden: .clear
        }
    }

    var help: String {
        switch c.status {
        case .issues(let n): "Aure found \(n) suggestion\(n == 1 ? "" : "s"). Click to review."
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
                Image(systemName: "text.badge.checkmark").foregroundStyle(.tint)
                Text(title).font(.headline)
                Spacer()
                Menu {
                    ForEach(Tone.allCases) { t in
                        Button("Rewrite as \(t.displayName)") { Task { await c.rewrite(tone: t); close() } }
                    }
                } label: { Image(systemName: "wand.and.stars") }
                    .menuStyle(.borderlessButton).fixedSize().help("Rewrite in a tone")
                    .disabled(c.result == nil)
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
                        Label("No issues found.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
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
                                             onAccept: { Task { await c.apply(issue) } },
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
                            Button("Replace all") { Task { await c.replaceAll(); close() } }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    var title: String {
        switch c.status {
        case .issues(let n): "\(n) suggestion\(n == 1 ? "" : "s")"
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
