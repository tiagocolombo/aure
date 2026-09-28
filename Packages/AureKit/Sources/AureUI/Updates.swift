import AppKit
import AureCore
import Observation
import Sparkle
@preconcurrency import UserNotifications

/// In-app updates through Sparkle. Aure is a menu bar app, so a background
/// check never pops a window over the app you are typing in: it posts a
/// notification and shows an "Install" button in the menu instead.
@MainActor
@Observable
public final class UpdateController: NSObject {
    /// Version found by a background check that the user has not acted on yet.
    public private(set) var availableVersion: String?
    /// False in `swift run`, tests and builds without a Sparkle signing key.
    public let isEnabled: Bool

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    private nonisolated static let notificationID = "aure.update-available"

    override public init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isEnabled = Bundle.main.bundleIdentifier != nil && !key.isEmpty && !key.hasPrefix("__")
        super.init()
        guard isEnabled else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: self)
        UNUserNotificationCenter.current().delegate = self
    }

    public var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Opens Sparkle's window: release info and an "Install Update" button.
    public func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private func updateFound(_ version: String) {
        availableVersion = version
        Log.info("update: \(version) available")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Aure \(version) is available"
            content.body = "Click to review and install the update."
            center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
        }
    }

    private func clearReminder() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Show Sparkle's window only when the user is already looking at Aure.
    public nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    public nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if handleShowingUpdate { availableVersion = version } else { updateFound(version) }
        }
    }

    public nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clearReminder() }
    }

    public nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            availableVersion = nil
            clearReminder()
        }
    }
}

extension UpdateController: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        await MainActor.run { checkForUpdates() }
    }
}
