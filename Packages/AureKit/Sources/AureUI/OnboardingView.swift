import AureCore
import AureModels
import SwiftUI

/// First run: welcome → choose and download a model → try it.
struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step = 0
    @State private var chosen: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: model
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            Divider()
            HStack {
                ForEach(0..<3) { i in
                    Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Open Aure Pad" : "Continue") { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !modelReadyOrDownloading)
            }
            .padding()
        }
        .frame(width: 600, height: 480)
        .onAppear { chosen = app.selectedModelID ?? app.recommendedModelID }
    }

    var welcome: some View {
        VStack(spacing: 16) {
            AureLogo(size: 76)
            Text("Welcome to Aure").font(.largeTitle.bold())
            Text("Grammar and tone help with local inference on your Mac. Aure does not send your writing to a cloud inference service.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 8) {
                Label("Pick a small local model (0.5–2.5 GB)", systemImage: "cpu")
                Label("Choose Informal, Formal or Strict formal", systemImage: "text.quote")
                Label("A red/green bubble in Slack, Chrome and other apps", systemImage: "circle.fill")
                Label("Aure Pad for anything else", systemImage: "menubar.rectangle")
            }
            .padding(.top, 8)
        }
    }

    var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a model").font(.title2.bold())
            Text("Detected \(app.hardware.cpuName), \(Int(app.hardware.memoryGB.rounded())) GB. You can change this later in Settings → Models.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(app.catalog) { m in
                    ModelRow(model: m)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    var done: some View {
        VStack(spacing: 14) {
            Image(systemName: app.engine.isReady ? "checkmark.seal.fill" : "hourglass")
                .font(.system(size: 50)).foregroundStyle(app.engine.isReady ? .green : .orange)
            Text(app.engine.isReady ? "You're all set" : "Almost there").font(.title.bold())
            Text(app.engine.isReady
                 ? "Aure lives in the menu bar at the top of your screen. Click its icon to switch tone, open Aure Pad or change settings."
                 : "\(app.engine.label). You can start using Aure Pad as soon as the model is ready.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            GroupBox {
                AccessibilityStatusView().frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            .frame(maxWidth: 460)
        }
    }

    var modelReadyOrDownloading: Bool {
        app.installedModels.isEmpty == false || app.downloads.values.contains { if case .downloading = $0 { true } else { false } }
            || app.selectedModel != nil
    }

    func next() {
        if step < 2 {
            step += 1
        } else {
            app.onboardingDone = true
            dismissWindow(id: "onboarding")
            openWindow(id: "pad")
        }
    }
}
