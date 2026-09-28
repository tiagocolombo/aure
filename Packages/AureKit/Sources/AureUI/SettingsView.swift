import AureCore
import AureInference
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
            EnginePicker()
            if app.engineKind == .ollama {
                ollamaModels
            } else {
                builtInModels
            }
            Text("Models run fully offline once downloaded.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .task { await app.refreshOllama() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { r in
            if case let .success(url) = r {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                app.importModel(from: url)
            }
        }
    }

    @ViewBuilder
    var ollamaModels: some View {
        if app.ollamaStatus.isRunning {
            // Catalog models first (same weights Aure is tested with), then everything else Ollama has.
            let others = app.ollamaModels.filter { m in !app.catalog.contains { $0.ollamaName == m.name } }
            List {
                Section("Tested with Aure") {
                    ForEach(app.catalog.filter { $0.ollamaName != nil }) { m in ModelRow(model: m) }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { m in OllamaModelRow(model: m) }
                    } header: {
                        Text("Your other Ollama models")
                    } footer: {
                        Text("Aure is tuned and tested with the models above; others may fix fewer errors or change correct text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        } else {
            OllamaUnavailableView().frame(maxHeight: .infinity)
        }
        HStack {
            Button {
                Task { await app.startEngine() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Checks Ollama again and reloads the model list")
            Spacer()
        }
        Text("Ollama stores these models. Remove one with `ollama rm <name>` in Terminal.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    var builtInModels: some View {
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
        .task { await app.refreshExternalModels() }
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
        if app.engineKind == .ollama {
            ollamaActions(fits)
        } else {
            builtInActions(fits)
        }
    }

    @ViewBuilder
    func builtInActions(_ fits: Bool) -> some View {
        switch app.downloads[model.id] ?? .idle {
        case .downloading(let p):
            DownloadProgress(value: p) { app.cancelDownload(model) }
        case .failed(let e):
            DownloadFailure(message: e) { app.download(model) }
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

    /// The same weights, downloaded and run by Ollama.
    @ViewBuilder
    func ollamaActions(_ fits: Bool) -> some View {
        if let name = model.ollamaName {
            switch app.ollamaPulls[name] ?? .idle {
            case .downloading(let p):
                DownloadProgress(value: p) { app.cancelPull(model) }
            case .failed(let e):
                DownloadFailure(message: e) { app.pullWithOllama(model) }
            case .idle:
                if app.ollamaModels.contains(where: { $0.name == name }) {
                    if app.ollamaModelName == name {
                        Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Use") { app.selectOllama(name) }
                    }
                } else {
                    Button("Download") { app.pullWithOllama(model) }
                        .disabled(!fits || !app.ollamaStatus.isRunning)
                        .help("Downloads \(name) with Ollama")
                }
            }
        }
    }
}

struct DownloadProgress: View {
    let value: Double
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ProgressView(value: value).frame(width: 110)
            HStack(spacing: 4) {
                Text("\(Int(value * 100))%").font(.caption).monospacedDigit()
                Button("Cancel", action: cancel).buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct DownloadFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .trailing) {
            Text(message).font(.caption).foregroundStyle(.red).frame(maxWidth: 160, alignment: .trailing)
            Button("Retry", action: retry)
        }
    }
}

/// Built-in llama.cpp or Ollama; shown only when Ollama is on this Mac.
struct EnginePicker: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.hasBuiltInEngine {
            if app.showsEngineChoice {
                HStack {
                    Text("Run models with").font(.callout)
                    Picker("Run models with", selection: Binding(get: { app.engineKind }, set: { app.use($0) })) {
                        ForEach(AppState.Engine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                }
            }
        } else {
            Text("This build of Aure runs models with Ollama.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Explains why Ollama models cannot be listed, with the way out.
struct OllamaUnavailableView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.ollamaStatus {
        case .running:
            EmptyView()
        case .notRunning:
            ContentUnavailableView {
                Label("Ollama is not running", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("Open Ollama, or run `ollama serve` in Terminal.")
            } actions: {
                if let url = OllamaClient.appURL() {
                    Button("Open Ollama") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(3))
                                await app.startEngine()
                            }
                        }
                    }
                }
            }
        case .notInstalled:
            ContentUnavailableView {
                Label("Ollama is not installed", systemImage: "arrow.down.circle")
            } description: {
                Text(app.hasBuiltInEngine ? "Install Ollama, or switch back to the built-in engine." : "This build of Aure needs Ollama to run models.")
            } actions: {
                Link("Download Ollama", destination: URL(string: "https://ollama.com/download")!)
            }
        }
    }
}

struct OllamaModelRow: View {
    @Environment(AppState.self) private var app
    let model: OllamaModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).font(.caption)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.quaternary))
                }
                Text([model.family, model.parameterSize, model.quantization].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.ollamaModelName == model.name {
                Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Use") { app.selectOllama(model.name) }
            }
        }
        .padding(.vertical, 2)
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
