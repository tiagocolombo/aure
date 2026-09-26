import AureAccessibility
import SwiftUI

/// Shows Accessibility status and helps grant it. Polls while visible so it
/// flips to "Enabled" as soon as the user toggles Aure on in System Settings.
struct AccessibilityStatusView: View {
    @Environment(AppState.self) private var app
    var compact = false

    var body: some View {
        Group {
            if app.accessibilityTrusted {
                Label(compact ? "Checking in other apps is on" : "Enabled: Aure can check text in Slack, Chrome, Mail and other apps.",
                      systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(compact ? "Enable checking in other apps" : "Allow Aure to read and fix the text you type in other apps.",
                          systemImage: "hand.raised")
                    if !compact {
                        Text("macOS asks for Accessibility permission. Open System Settings → Privacy & Security → Accessibility and turn on Aure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Grant Accessibility…") {
                        AccessibilityPermission.request()
                        AccessibilityPermission.openSystemSettings()
                    }
                    .controlSize(compact ? .small : .regular)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let trusted = AccessibilityPermission.isTrusted
                if trusted != app.accessibilityTrusted {
                    app.accessibilityTrusted = trusted
                    if trusted { app.coordinator?.restart() }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
