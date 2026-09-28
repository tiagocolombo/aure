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
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 500)
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @State private var launchAtLogin = false
    @State private var autoUpdates = false

    var body: some View {
        @Bindable var app = app
        Form {
            Picker("Default tone", selection: $app.tone) {
                ForEach(Tone.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("English", selection: $app.dialect) {
                ForEach(Dialect.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Suggestions", selection: Binding(get: { Strictness.nearest(app.minConfidence) },
                                                     set: { app.minConfidence = $0.threshold })) {
                ForEach(Strictness.allCases) { Text($0.title).tag($0) }
            }
            Text(Strictness.nearest(app.minConfidence).help).font(.caption).foregroundStyle(.secondary)
            Toggle("Optional better-writing suggestions", isOn: $app.writingSuggestionsEnabled)
            Text("After grammar checks, offer one model-generated alternative for short text. Nothing changes until you apply it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Pause checking", isOn: $app.paused)
            Toggle("Launch Aure at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in app.launchAtLogin = v }
            LabeledContent("Aure Pad shortcut", value: "⌥⌘P (from the menu bar)")
            if app.updates.isEnabled {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $autoUpdates)
                        .onChange(of: autoUpdates) { _, v in app.updates.automaticallyChecks = v }
                    Text("Once a day Aure asks GitHub whether a newer release exists. Your writing is never sent.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(app.updates.availableVersion.map { "Install Aure \($0)…" } ?? "Check for Updates…") {
                        app.updates.checkForUpdates()
                    }
                }
            }
            Section("Checking in other apps") {
                AccessibilityStatusView()
                Text("A small bubble appears in the corner of the field you are typing in: green when it looks good, yellow for optional writing improvements, red for errors (which take priority). Click it to review and replace. Password fields, terminals, code editors and password managers are never read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = app.launchAtLogin
            autoUpdates = app.updates.automaticallyChecks
        }
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
                if !app.externalModels.isEmpty {
                    Section {
                        ForEach(app.externalModels) { m in ExternalModelRow(model: m) }
                    } header: {
                        Text("From other apps on this Mac")
                    } footer: {
                        Text("Used where they are, without copying. Aure is tuned and tested with the models above; others may fix fewer errors or change correct text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("Import GGUF…") { importing = true }
                Button("Show models folder") { NSWorkspace.shared.open(app.store.directory) }
                Button {
                    Task { await app.refreshExternalModels() }
                } label: {
                    Label("Find models from other apps", systemImage: "arrow.clockwise")
                }
                .disabled(app.scanningExternalModels)
                .help("Looks in LM Studio, Ollama, llama.cpp, Hugging Face, Jan and GPT4All folders")
                if app.scanningExternalModels { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Models run fully offline once downloaded.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .task { await app.refreshExternalModels() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { r in
            if case let .success(url) = r {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                app.importModel(from: url)
            }
        }
    }
}

struct ExternalModelRow: View {
    @Environment(AppState.self) private var app
    let model: ExternalModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    Text(model.info.sizeDescription).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Text([model.source, model.architecture].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.matches(app.selectedModelID) {
                Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Use") { app.select(model.info) }
            }
        }
        .padding(.vertical, 2)
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
