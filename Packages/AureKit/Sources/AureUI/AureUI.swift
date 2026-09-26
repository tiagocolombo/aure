import AppKit
import AureCore
import SwiftUI

public enum AureMain {
    @MainActor public static func run() {
        SelfTest.runIfRequested()
        AureApplication.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    var coordinator: CheckCoordinator?
    var bubble: BubbleController?

    /// Starts system-wide checking (bubble in other apps). Safe to call again.
    @MainActor
    func startIntegration(_ state: AppState) {
        guard coordinator == nil else { return }
        let c = CheckCoordinator(app: state)
        coordinator = c
        state.coordinator = c
        bubble = BubbleController(coordinator: c, app: state)
        c.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Make sure llama-server does not outlive the app.
        guard let state else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await state.stopEngine(); sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
    }
}

struct AureApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    init() {
        // Menu bar only; no Dock icon (LSUIElement in Info.plist covers the
        // bundled app, this covers `swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(state)
        } label: {
            MenuBarIcon(state: state, delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        Window("Aure Pad", id: "pad") {
            PadView().environment(state)
        }
        .defaultSize(width: 620, height: 520)
        .keyboardShortcut("p", modifiers: [.option, .command])

        Window("Welcome to Aure", id: "onboarding") {
            OnboardingView().environment(state)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView().environment(state)
        }
    }
}

/// The icon in the top menu bar.
struct MenuBarIcon: View {
    let state: AppState
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .task {
                // Start the engine at launch; show onboarding on first run.
                delegate.state = state
                delegate.startIntegration(state)
                await state.startEngine()
            }
            .task {
                if !state.onboardingDone {
                    try? await Task.sleep(for: .milliseconds(400))
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "onboarding")
                }
            }
    }

    var symbol: String {
        if state.paused { return "text.badge.xmark" }
        switch state.engine {
        case .ready:
            if case .issues = state.coordinator?.status { return "exclamationmark.bubble" }
            return "text.badge.checkmark"
        case .loading: return "hourglass"
        case .noModel, .failed: return "text.badge.minus"
        }
    }
}

struct MenuContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aure").font(.headline)
                Spacer()
                StatusDot(status: app.engine)
                Text(app.engine.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            AccessibilityStatusView(compact: true)
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Tone").font(.caption).foregroundStyle(.secondary)
                Picker("Tone", selection: $app.tone) {
                    ForEach(Tone.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Pause Aure", isOn: $app.paused).toggleStyle(.switch).controlSize(.small)

            if !app.installedModels.isEmpty {
                Picker("Model", selection: Binding(get: { app.selectedModelID ?? "" },
                                                   set: { id in if let m = app.catalog.first(where: { $0.id == id }) { app.select(m) } })) {
                    ForEach(app.installedModels) { Text("\($0.name) (\($0.sizeDescription))").tag($0.id) }
                }
                .controlSize(.small)
            }

            Divider()

            MenuButton(title: "Open Aure Pad", systemImage: "square.and.pencil", shortcut: "⌥⌘P") {
                activate(); openWindow(id: "pad")
            }
            MenuButton(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                activate(); openSettings()
            }
            if !app.onboardingDone || app.engine == .noModel {
                MenuButton(title: "Set up Aure…", systemImage: "sparkles") {
                    activate(); openWindow(id: "onboarding")
                }
            }
            Divider()
            MenuButton(title: "Quit Aure", systemImage: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }

    func activate() { NSApp.activate(ignoringOtherApps: true) }
}

struct MenuButton: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
