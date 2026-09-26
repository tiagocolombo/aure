import AureCore
import AureModels
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ModelsSettings().tabItem { Label("Models", systemImage: "cpu") }
            ToneSettings().tabItem { Label("Voice & Tone", systemImage: "text.quote") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 620, height: 500)
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var app = app
        Form {
            Picker("Default tone", selection: $app.tone) {
                ForEach(Tone.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("English", selection: $app.dialect) {
                ForEach(Dialect.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Pause checking", isOn: $app.paused)
            Toggle("Launch Aure at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in app.launchAtLogin = v }
            LabeledContent("Aure Pad shortcut", value: "⌥⌘P (from the menu bar)")
            Section {
                Text("Checking in other apps (Slack, Chrome/Gmail) with the red/green bubble arrives in the next milestone. Until then, use Aure Pad.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = app.launchAtLogin }
    }
}

struct ModelsSettings: View {
    @Environment(AppState.self) private var app
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac: \(app.hardware.cpuName)").font(.callout)
                    Text("\(Int(app.hardware.memoryGB.rounded())) GB memory · \(app.hardware.isAppleSilicon ? "Apple Silicon (GPU accelerated)" : "Intel (CPU only)")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(status: app.engine)
                    Text(app.engine.label).font(.caption).lineLimit(2)
                }
            }
            List {
                ForEach(app.catalog) { m in
                    ModelRow(model: m)
                }
                ForEach(app.store.importedModels(catalog: app.catalog), id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).fontWeight(.medium)
                            Text("Imported GGUF").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.selectedModelID == "file:" + url.lastPathComponent {
                            Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Use") {
                                app.selectedModelID = "file:" + url.lastPathComponent
                                Task { await app.startEngine() }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("Import GGUF…") { importing = true }
                Button("Show models folder") { NSWorkspace.shared.open(app.store.directory) }
                Spacer()
                Text("Models run fully offline once downloaded.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { r in
            if case let .success(url) = r {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                app.importModel(from: url)
            }
        }
    }
}

struct ModelRow: View {
    @Environment(AppState.self) private var app
    let model: ModelInfo

    var body: some View {
        let fit = ModelCatalog.fit(model, isAppleSilicon: app.hardware.isAppleSilicon, memoryGB: app.hardware.memoryGB)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    Text(model.sizeDescription).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    if model.id == app.recommendedModelID {
                        Text("Recommended").font(.caption).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.blue))
                    }
                }
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
                if let note = fit.note {
                    Text(note).font(.caption).foregroundStyle(fit.ok ? .orange : .red)
                }
            }
            Spacer()
            actions(fit.ok)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func actions(_ fits: Bool) -> some View {
        switch app.downloads[model.id] ?? .idle {
        case .downloading(let p):
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: p).frame(width: 110)
                HStack(spacing: 4) {
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                    Button("Cancel") { app.cancelDownload(model) }.buttonStyle(.link).font(.caption)
                }
            }
        case .failed(let e):
            VStack(alignment: .trailing) {
                Text(e).font(.caption).foregroundStyle(.red).frame(maxWidth: 160, alignment: .trailing)
                Button("Retry") { app.download(model) }
            }
        case .idle:
            if app.isInstalled(model) {
                HStack {
                    if app.selectedModelID == model.id {
                        Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Use") { app.select(model) }
                    }
                    Menu {
                        Button("Delete", role: .destructive) { app.delete(model) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            } else {
                Button("Download") { app.download(model) }.disabled(!fits)
            }
        }
    }
}

struct ToneSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            ForEach(Tone.allCases) { tone in
                Section(tone.displayName) {
                    TextEditor(text: binding(tone))
                        .font(.callout)
                        .frame(height: 64)
                    HStack {
                        Spacer()
                        Button("Reset to default") {
                            app.toneDescriptions[tone] = ToneDefinition.default(tone).description
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
            Section {
                Text("A guided voice assistant and learning from your accepted/dismissed suggestions arrive in a later milestone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func binding(_ tone: Tone) -> Binding<String> {
        Binding(get: { app.toneDescriptions[tone] ?? "" },
                set: { app.toneDescriptions[tone] = $0 })
    }
}

struct PrivacySettings: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Form {
            Section {
                Label("Your text never leaves this Mac.", systemImage: "lock.shield")
                Label("Models run locally with llama.cpp; the only network use is downloading a model you choose.",
                      systemImage: "arrow.down.circle")
                Label("Aure does not store your writing.", systemImage: "externaldrive.badge.xmark")
            }
            Section("Files") {
                LabeledContent("Models", value: app.store.directory.path)
                LabeledContent("Log", value: "~/Library/Logs/Aure/llama-server.log")
            }
            Section {
                LabeledContent("Version", value: AureVersion.string)
            }
        }
        .formStyle(.grouped)
    }
}
