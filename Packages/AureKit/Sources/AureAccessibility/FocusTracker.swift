import AppKit
import ApplicationServices
import AureCore
import Foundation

/// A text field in another app, as seen through Accessibility.
public struct FocusedField: @unchecked Sendable, Equatable {
    public var element: AXElement
    public var pid: pid_t
    public var bundleId: String?
    public var appName: String?
    public var role: String
    public var text: String
    public var selection: Range<Int>?
    public var frame: CGRect?
    public var caretRect: CGRect?
    public var isWebArea: Bool

    public static func == (a: FocusedField, b: FocusedField) -> Bool {
        a.element == b.element && a.text == b.text && a.selection == b.selection && a.frame == b.frame
    }
}

/// Per-app rules.
public enum AppRules {
    /// Apps where Aure never reads text.
    public static let blocked: Set<String> = [
        // Password managers: their fields are not always marked secure.
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc", "me.proton.pass.electron",
        "in.sinew.Enpass-Desktop", "com.keepersecurity.passwordmanager",
        // Terminals and code editors: commands, tokens and code, not prose.
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "dev.zed.Zed",
        "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij", "com.sublimetext.4",
        "com.tiagocolombo.aure",
    ]

    /// Electron / Chromium apps: expose their AX tree only when asked.
    public static let electron: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.google.Chrome", "com.microsoft.teams2", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "notion.id", "com.hnc.Discord",
    ]

    public static let editableRoles: Set<String> = [
        kAXTextAreaRole as String, kAXTextFieldRole as String, kAXComboBoxRole as String, "AXSearchField",
    ]
}

/// What Aure currently sees in the frontmost app (for the menu bar status).
public enum TrackerActivity: Equatable, Sendable {
    case noPermission
    case blocked(app: String)
    case noTextField(app: String)
    case field(app: String)
}

/// Tracks the focused editable text field system-wide via AXObserver.
@MainActor
public final class FocusTracker {
    public var onChange: ((FocusedField?) -> Void)?
    public var onActivity: ((TrackerActivity) -> Void)?
    public private(set) var current: FocusedField?
    public private(set) var activity: TrackerActivity = .noPermission {
        didSet { if activity != oldValue { onActivity?(activity) } }
    }
    static let ownBundleId = "com.tiagocolombo.aure"

    private var observer: AXObserver?
    private var observedPid: pid_t?
    private var appObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var enhanced = Set<pid_t>()

    public init() {}

    public func start() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.attach(to: app) }
        }
        attach(to: NSWorkspace.shared.frontmostApplication)
        // Safety net: some apps (web views) do not send every notification.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func stop() {
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        pollTimer?.invalidate()
        detach()
    }

    private func attach(to app: NSRunningApplication?) {
        // Opening Aure's own menu or windows must not reset what we track.
        if app?.bundleIdentifier == Self.ownBundleId { return }
        detach()
        guard AccessibilityPermission.isTrusted else {
            activity = .noPermission
            publish(nil)
            return
        }
        guard let app, let bundleId = app.bundleIdentifier, !AppRules.blocked.contains(bundleId) else {
            activity = .blocked(app: app?.localizedName ?? "this app")
            publish(nil)
            return
        }
        let pid = app.processIdentifier
        let appEl = AXElement.application(pid: pid)
        appEl.setTimeout(0.25)

        // Chromium/Electron: turn on the accessibility tree (Slack, Chrome...).
        if AppRules.electron.contains(bundleId), !enhanced.contains(pid) {
            appEl.set("AXManualAccessibility", kCFBooleanTrue)
            appEl.set("AXEnhancedUserInterface", kCFBooleanTrue)
            enhanced.insert(pid)
        }

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.refresh() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedUIElementChangedNotification, kAXValueChangedNotification,
                  kAXSelectedTextChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(obs, appEl.ref, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPid = pid
        refresh()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPid = nil
    }

    /// Re-reads the focused element.
    public func refresh() {
        guard AccessibilityPermission.isTrusted else {
            activity = .noPermission
            publish(nil)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if app.bundleIdentifier == Self.ownBundleId { return }
        let name = app.localizedName ?? "this app"
        guard let bundleId = app.bundleIdentifier, !AppRules.blocked.contains(bundleId) else {
            activity = .blocked(app: name)
            publish(nil)
            return
        }
        if observedPid != app.processIdentifier { attach(to: app); return }
        let appEl = AXElement.application(pid: app.processIdentifier)
        let field = appEl.element(kAXFocusedUIElementAttribute)
            .flatMap { Self.read($0, pid: app.processIdentifier, bundleId: bundleId, appName: name) }
        activity = field == nil ? .noTextField(app: name) : .field(app: name)
        publish(field)
    }

    private func publish(_ f: FocusedField?) {
        guard f != current else { return }
        current = f
        onChange?(f)
    }

    /// Reads an element if it is an editable, non-secure text field.
    static func read(_ el: AXElement, pid: pid_t, bundleId: String?, appName: String?) -> FocusedField? {
        EditableTarget.read(el, isSecure: { $0.subrole == kAXSecureTextFieldSubrole as String },
                            ancestor: { $0.element("AXEditableAncestor") }) { target in
            guard target.pid == pid else { return nil }
            return readEditable(target, pid: pid, bundleId: bundleId, appName: appName)
        }
    }

    private static func readEditable(_ el: AXElement, pid: pid_t, bundleId: String?, appName: String?) -> FocusedField? {
        el.setTimeout(0.25)
        guard let role = el.role else { return nil }
        if role == kAXTextFieldRole as String, el.subrole == kAXSecureTextFieldSubrole as String { return nil }

        let isWeb = role == "AXWebArea" || (el.attribute("AXEditableAncestor") as AnyObject?) != nil
        guard AppRules.editableRoles.contains(role) || isWeb else { return nil }
        // Web: only editable content (contenteditable / textarea).
        if isWeb, !AppRules.editableRoles.contains(role), !el.isSettable(kAXValueAttribute as String),
           el.selectedRange == nil { return nil }
        guard let text = el.text else { return nil }

        let selection = el.selectedRange
        var caret: CGRect?
        if let sel = selection {
            let caretRange = sel.count > 0 ? sel : max(0, sel.lowerBound - 1)..<max(0, sel.lowerBound)
            caret = el.bounds(for: caretRange)
        }
        return FocusedField(element: el, pid: pid, bundleId: bundleId, appName: appName, role: role, text: text,
                            selection: selection, frame: el.frame, caretRect: caret, isWebArea: isWeb)
    }
}
