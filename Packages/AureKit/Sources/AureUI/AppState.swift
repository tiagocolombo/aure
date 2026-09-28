import AureAccessibility
import AureCore
import AureInference
import AureModels
import Foundation
import Observation
import ServiceManagement

/// Single source of truth for the app.
@MainActor
@Observable
public final class AppState {
    public enum EngineStatus: Equatable {
        case noModel
        case loading(String)
        case ready(String)
        case failed(String)

        public var label: String {
            switch self {
            case .noModel: "No model selected"
            case .loading(let n): "Loading \(n)…"
            case .ready(let n): "\(n) ready"
            case .failed(let e): e
            }
        }

        public var isReady: Bool { if case .ready = self { true } else { false } }
    }

    /// What runs the model: the llama-server bundled in the app, or a local Ollama server.
    public enum Engine: String, CaseIterable, Identifiable {
        case builtIn, ollama

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .builtIn: "Built-in (llama.cpp)"
            case .ollama: "Ollama"
            }
        }
    }

    public enum OllamaStatus: Equatable {
        case notInstalled
        case notRunning
        case running(version: String)

        public var isRunning: Bool { if case .running = self { true } else { false } }
    }

    public enum DownloadState: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    // MARK: Settings (persisted in UserDefaults)

    public var writingSuggestionsEnabled: Bool {
        didSet {
            defaults.set(writingSuggestionsEnabled, forKey: Keys.writingSuggestions)
            coordinator?.invalidateReview()
        }
    }

    public var tone: Tone { didSet { defaults.set(tone.rawValue, forKey: Keys.tone); coordinator?.invalidateReview() } }
    public var dialect: Dialect { didSet { defaults.set(dialect.rawValue, forKey: Keys.dialect); coordinator?.invalidateReview() } }
    public var selectedModelID: String? { didSet { defaults.set(selectedModelID, forKey: Keys.model); coordinator?.invalidateReview() } }
    public var paused: Bool { didSet { defaults.set(paused, forKey: Keys.paused); coordinator?.invalidateReview() } }
    /// Change with `use(_ engine:)`, which also restarts the engine.
    public internal(set) var engineKind: Engine {
        didSet { defaults.set(engineKind.rawValue, forKey: Keys.engine); coordinator?.invalidateReview() }
    }
    /// The Ollama model in use when `engineKind == .ollama`, e.g. "qwen3:4b".
    public var ollamaModelName: String? {
        didSet { defaults.set(ollamaModelName, forKey: Keys.ollamaModel); coordinator?.invalidateReview() }
    }
    public var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Keys.onboarding) } }
    /// Suggestion strictness: hide edits the model was less sure about.
    public var minConfidence: Double {
        didSet {
            coordinator?.invalidateReview()
            defaults.set(minConfidence, forKey: Keys.minConfidence)
            Task { await correction.setMinConfidence(minConfidence) }
        }
    }
    public var toneDescriptions: [Tone: String] {
        didSet {
            coordinator?.invalidateReview()
            defaults.set(Dictionary(uniqueKeysWithValues: toneDescriptions.map { ($0.key.rawValue, $0.value) }),
                         forKey: Keys.toneDescriptions)
            Task { await pushToneDefinitions() }
        }
    }

    // MARK: Runtime

    public private(set) var engine: EngineStatus = .noModel
    public var downloads: [String: DownloadState] = [:]
    public let catalog: [ModelInfo]
    /// GGUF models other local-LLM tools (LM Studio, Ollama, llama.cpp, ...) already downloaded.
    public private(set) var externalModels: [ExternalModel] = []
    public private(set) var scanningExternalModels = false
    public private(set) var ollamaStatus: OllamaStatus = .notInstalled
    /// Chat models the local Ollama server has pulled.
    public private(set) var ollamaModels: [OllamaModel] = []
    /// `ollama pull` progress, by Ollama model name.
    public var ollamaPulls: [String: DownloadState] = [:]
    public let hardware = Hardware.current
    public let store: ModelStore
    public let correction = CorrectionService()
    public let updates = UpdateController()
    public var lastResult: CheckResult?
    public var coordinator: CheckCoordinator?
    public var accessibilityTrusted = AccessibilityPermission.isTrusted

    @ObservationIgnored private let server: LlamaServerProcess?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let ollama = OllamaClient()
    @ObservationIgnored private var pullTasks: [String: Task<Void, Never>] = [:]
    /// The Ollama model Aure asked Ollama to keep loaded, unloaded when switching away.
    @ObservationIgnored private var loadedOllamaModel: String?

    enum Keys {
        static let tone = "tone", dialect = "dialect", model = "selectedModelID", paused = "paused"
        static let onboarding = "onboardingDone", toneDescriptions = "toneDescriptions"
        static let minConfidence = "minConfidence"
        static let writingSuggestions = "writingSuggestionsEnabled"
        static let engine = "engine", ollamaModel = "ollamaModel"
    }

    public init(defaults: UserDefaults = .standard, store: ModelStore = ModelStore()) {
        self.defaults = defaults
        self.store = store
        writingSuggestionsEnabled = defaults.object(forKey: Keys.writingSuggestions) as? Bool ?? true
        catalog = ModelCatalog.load()
        tone = Tone(rawValue: defaults.string(forKey: Keys.tone) ?? "") ?? .formal
        dialect = Dialect(rawValue: defaults.string(forKey: Keys.dialect) ?? "") ?? .enUS
        selectedModelID = defaults.string(forKey: Keys.model)
        paused = defaults.bool(forKey: Keys.paused)
        ollamaModelName = defaults.string(forKey: Keys.ollamaModel)
        onboardingDone = defaults.bool(forKey: Keys.onboarding)
        minConfidence = defaults.object(forKey: Keys.minConfidence) as? Double ?? Strictness.balanced.threshold
        let saved = defaults.dictionary(forKey: Keys.toneDescriptions) as? [String: String] ?? [:]
        toneDescriptions = Dictionary(uniqueKeysWithValues: Tone.allCases.map {
            ($0, saved[$0.rawValue] ?? ToneDefinition.default($0).description)
        })

        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Aure/llama-server.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Ollama-only builds (AURE_ENGINE=ollama scripts/build-app.sh) never run llama-server.
        let ollamaOnly = Bundle.main.object(forInfoDictionaryKey: "AureEngine") as? String == "ollama"
        server = ollamaOnly ? nil
            : LlamaServerProcess.locateExecutable().map { LlamaServerProcess(executable: $0, logURL: logURL) }
        // Built without llama.cpp (see README): Ollama is the only engine.
        engineKind = server == nil ? .ollama : Engine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .builtIn
    }

    /// This build ships llama-server.
    public var hasBuiltInEngine: Bool { server != nil }

    /// Offer the engine choice only when both exist; the built-in engine stays the default.
    public var showsEngineChoice: Bool { hasBuiltInEngine && ollamaStatus != .notInstalled }

    public var recommendedModelID: String {
        ModelCatalog.recommendedID(isAppleSilicon: hardware.isAppleSilicon, memoryGB: hardware.memoryGB)
    }

    public var selectedModel: ModelInfo? {
        catalog.first { $0.id == selectedModelID } ?? importedModel ?? externalModel
    }

    /// Models from other tools are used where they are: id "path:<absolute path>".
    var externalModel: ModelInfo? {
        guard let id = selectedModelID, id.hasPrefix(ExternalModels.idPrefix) else { return nil }
        if let known = externalModels.first(where: { $0.matches(id) }) { return known.info }
        // Before the first scan finishes: rebuild from the path so the engine can start at launch.
        // The saved id is only a preference: never load a file outside the other tools' model folders.
        let url = URL(fileURLWithPath: String(id.dropFirst(ExternalModels.idPrefix.count)))
        guard ExternalModels.isInKnownLocation(url), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ExternalModel(url: url, name: url.deletingPathExtension().lastPathComponent, source: "Other app",
                             bytes: 0, architecture: nil).info
    }

    /// Looks for models from other tools off the main thread.
    public func refreshExternalModels() async {
        guard !scanningExternalModels else { return }
        scanningExternalModels = true
        let exclude = store.directory
        let found = await Task.detached(priority: .utility) { ExternalModels.scan(exclude: exclude) }.value
        externalModels = found
        scanningExternalModels = false
    }

    /// Imported GGUFs use their file name as id ("file:<name>").
    var importedModel: ModelInfo? {
        guard let id = selectedModelID, id.hasPrefix("file:") else { return nil }
        let name = String(id.dropFirst(5))
        let url = store.directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ModelInfo(id: id, name: name, repo: "", file: name, family: "custom", summary: "Imported",
                         minRAMGB: 0, license: "", bytes: 0, sha256: "", url: url)
    }

    public var installedModels: [ModelInfo] { catalog.filter { store.isInstalled($0) } }

    public func isInstalled(_ m: ModelInfo) -> Bool {
        switch m.family {
        case "custom", ExternalModels.family: FileManager.default.fileExists(atPath: modelURL(for: m).path)
        default: store.isInstalled(m)
        }
    }

    /// Where the weights are: Aure's models folder, or the other tool's folder for external models.
    func modelURL(for m: ModelInfo) -> URL {
        m.family == ExternalModels.family ? m.url : store.localURL(for: m)
    }

    // MARK: Engine

    public func use(_ engine: Engine) {
        guard engine != engineKind, engine == .ollama || hasBuiltInEngine else { return }
        engineKind = engine
        Task { await startEngine() }
    }

    public func startEngine() async {
        await pushToneDefinitions()
        if engineKind == .ollama {
            await startOllama()
            return
        }
        if let loaded = loadedOllamaModel {
            loadedOllamaModel = nil
            await ollama.unload(loaded)
        }
        guard let model = selectedModel, isInstalled(model) else {
            engine = .noModel
            await correction.setProvider(nil)
            return
        }
        guard let server else {
            engine = .failed("llama-server is missing from the app bundle")
            return
        }
        engine = .loading(model.name)
        do {
            let slots = hardware.recommendedParallelSlots
            let provider = try await server.start(.init(modelPath: modelURL(for: model), parallel: slots))
            await correction.setProvider(provider)
            await correction.setMaxParallel(slots)
            engine = .ready(model.name)
            // Warm up so the first real check is fast.
            _ = try? await correction.check(CheckRequest(text: "This are a warm up.", tone: .formal, dialect: dialect))
            await correction.clearCache()
        } catch {
            engine = .failed(error.localizedDescription)
            await correction.setProvider(nil)
        }
    }

    public func stopEngine() async {
        await server?.stop()
    }

    private func startOllama() async {
        await server?.stop()
        await refreshOllama()
        guard ollamaStatus.isRunning else {
            engine = .failed(ollamaStatus == .notInstalled ? "Ollama is not installed" : "Ollama is not running")
            await correction.setProvider(nil)
            return
        }
        guard let name = ollamaModelName, ollamaModels.contains(where: { $0.name == name }) else {
            engine = .noModel
            await correction.setProvider(nil)
            return
        }
        let display = ollamaDisplayName(name)
        engine = .loading(display)
        do {
            let provider = try await ollama.provider(for: name)
            if let old = loadedOllamaModel, old != name { await ollama.unload(old) }
            loadedOllamaModel = name
            await correction.setProvider(provider)
            // Ollama queues what it cannot run at once (OLLAMA_NUM_PARALLEL).
            await correction.setMaxParallel(hardware.recommendedParallelSlots)
            // Ollama loads the model on the first request: warm up before reporting ready,
            // so a model Ollama cannot run shows as failed instead of failing every check.
            do {
                _ = try await correction.check(CheckRequest(text: "This are a warm up.", tone: .formal, dialect: dialect))
            } catch let e as AureError {
                // A poor answer is fine for a warm-up; an Ollama error is not.
                if case .server = e { throw e }
            }
            await correction.clearCache()
            engine = .ready(display)
        } catch {
            engine = .failed(error.localizedDescription)
            await correction.setProvider(nil)
        }
    }

    /// Detects Ollama and lists its chat models.
    public func refreshOllama() async {
        if let version = await ollama.version() {
            ollamaStatus = .running(version: version)
            ollamaModels = ((try? await ollama.models()) ?? []).filter(\.canChat)
        } else {
            ollamaStatus = OllamaClient.isInstalled() ? .notRunning : .notInstalled
            ollamaModels = []
        }
    }

    /// Catalog models pulled through Ollama keep their catalog name ("Qwen3 4B").
    public func ollamaDisplayName(_ name: String) -> String {
        catalog.first { $0.ollamaName == name }?.name ?? name
    }

    public func selectOllama(_ name: String) {
        ollamaModelName = name
        Task { await startEngine() }
    }

    /// Downloads a catalog model with `ollama pull` and uses it when done.
    public func pullWithOllama(_ m: ModelInfo) {
        guard let name = m.ollamaName, pullTasks[name] == nil else { return }
        ollamaPulls[name] = .downloading(0)
        pullTasks[name] = Task { [weak self] in
            guard let self else { return }
            do {
                try await ollama.pull(name) { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.ollamaPulls[name] { self?.ollamaPulls[name] = .downloading(p) }
                    }
                }
                ollamaPulls[name] = .idle
                await refreshOllama()
                selectOllama(name)
            } catch {
                ollamaPulls[name] = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            pullTasks[name] = nil
        }
    }

    /// Ollama keeps the partial download and resumes it on the next pull.
    public func cancelPull(_ m: ModelInfo) {
        guard let name = m.ollamaName else { return }
        pullTasks[name]?.cancel()
        pullTasks[name] = nil
        ollamaPulls[name] = .idle
    }

    public func select(_ model: ModelInfo) {
        selectedModelID = model.id
        Task { await startEngine() }
    }

    private func pushToneDefinitions() async {
        await correction.setMinConfidence(minConfidence)
        for (tone, text) in toneDescriptions {
            await correction.setToneDefinition(ToneDefinition(tone: tone, description: text))
        }
    }

    // MARK: Checking

    public func check(_ text: String, mode: CheckMode = .correct, tone: Tone? = nil) async throws -> CheckResult {
        let r = try await correction.check(CheckRequest(text: text, tone: tone ?? self.tone, mode: mode, dialect: dialect))
        lastResult = r
        return r
    }

    /// One optional model alternative, never an automatic replacement. The cap keeps
    /// background style work bounded; long documents still receive grammar checks.
    public func suggestWriting(_ text: String, tone: Tone? = nil) async throws -> WritingSuggestion? {
        guard writingSuggestionsEnabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 1200 else { return nil }
        try Task.checkCancellation()
        let targetTone = tone ?? self.tone
        let rewrite = try await correction.check(CheckRequest(text: text, tone: targetTone, mode: .rewrite, dialect: dialect))
        try Task.checkCancellation()
        guard writingSuggestionsEnabled else { return nil }
        return WritingSuggestion(original: text, replacement: rewrite.corrected, tone: targetTone,
                                 soundsAIWritten: rewrite.soundsAIWritten)
    }

    // MARK: Downloads

    public func download(_ m: ModelInfo, selectWhenDone: Bool = true) {
        guard downloadTasks[m.id] == nil else { return }
        downloads[m.id] = .downloading(0)
        downloadTasks[m.id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await store.download(m) { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.downloads[m.id] { self?.downloads[m.id] = .downloading(p) }
                    }
                }
                downloads[m.id] = .idle
                if selectWhenDone { select(m) }
            } catch is CancellationError {
                downloads[m.id] = .idle
            } catch {
                downloads[m.id] = .failed(error.localizedDescription)
            }
            downloadTasks[m.id] = nil
        }
    }

    public func cancelDownload(_ m: ModelInfo) {
        downloadTasks[m.id]?.cancel()
        downloadTasks[m.id] = nil
        downloads[m.id] = .idle
    }

    public func delete(_ m: ModelInfo) {
        if selectedModelID == m.id {
            selectedModelID = nil
            Task { await stopEngine(); await correction.setProvider(nil); engine = .noModel }
        }
        try? store.delete(m)
        downloads[m.id] = .idle
    }

    public func importModel(from url: URL) {
        guard let dest = try? store.importModel(from: url) else { return }
        selectedModelID = "file:" + dest.lastPathComponent
        Task { await startEngine() }
    }

    // MARK: Launch at login

    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

/// User-facing presets for `minConfidence` (Settings → General).
public enum Strictness: String, CaseIterable, Identifiable {
    case all, balanced, onlySure

    public var id: String { rawValue }

    public var threshold: Double {
        switch self {
        case .all: 0
        case .balanced: 0.7
        case .onlySure: 0.9
        }
    }

    public var title: String {
        switch self {
        case .all: "Show everything"
        case .balanced: "Balanced"
        case .onlySure: "Only when sure"
        }
    }

    public var help: String {
        switch self {
        case .all: "Show every change the model makes, even ones it was unsure about."
        case .balanced: "Hide changes the model was less than 70% sure about."
        case .onlySure: "Only show changes the model was at least 90% sure about. Fewer, safer suggestions."
        }
    }

    public static func nearest(_ t: Double) -> Strictness {
        allCases.min { abs($0.threshold - t) < abs($1.threshold - t) } ?? .balanced
    }
}
