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

    public enum DownloadState: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    // MARK: Settings (persisted in UserDefaults)

    public var tone: Tone { didSet { defaults.set(tone.rawValue, forKey: Keys.tone) } }
    public var dialect: Dialect { didSet { defaults.set(dialect.rawValue, forKey: Keys.dialect) } }
    public var selectedModelID: String? { didSet { defaults.set(selectedModelID, forKey: Keys.model) } }
    public var paused: Bool { didSet { defaults.set(paused, forKey: Keys.paused) } }
    public var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Keys.onboarding) } }
    public var toneDescriptions: [Tone: String] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: toneDescriptions.map { ($0.key.rawValue, $0.value) }),
                         forKey: Keys.toneDescriptions)
            Task { await pushToneDefinitions() }
        }
    }

    // MARK: Runtime

    public private(set) var engine: EngineStatus = .noModel
    public var downloads: [String: DownloadState] = [:]
    public let catalog: [ModelInfo]
    public let hardware = Hardware.current
    public let store: ModelStore
    public let correction = CorrectionService()
    public var lastResult: CheckResult?
    public var coordinator: CheckCoordinator?
    public var accessibilityTrusted = AccessibilityPermission.isTrusted

    @ObservationIgnored private let server: LlamaServerProcess?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]

    enum Keys {
        static let tone = "tone", dialect = "dialect", model = "selectedModelID", paused = "paused"
        static let onboarding = "onboardingDone", toneDescriptions = "toneDescriptions"
    }

    public init(defaults: UserDefaults = .standard, store: ModelStore = ModelStore()) {
        self.defaults = defaults
        self.store = store
        catalog = ModelCatalog.load()
        tone = Tone(rawValue: defaults.string(forKey: Keys.tone) ?? "") ?? .formal
        dialect = Dialect(rawValue: defaults.string(forKey: Keys.dialect) ?? "") ?? .enUS
        selectedModelID = defaults.string(forKey: Keys.model)
        paused = defaults.bool(forKey: Keys.paused)
        onboardingDone = defaults.bool(forKey: Keys.onboarding)
        let saved = defaults.dictionary(forKey: Keys.toneDescriptions) as? [String: String] ?? [:]
        toneDescriptions = Dictionary(uniqueKeysWithValues: Tone.allCases.map {
            ($0, saved[$0.rawValue] ?? ToneDefinition.default($0).description)
        })

        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Aure/llama-server.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        server = LlamaServerProcess.locateExecutable().map { LlamaServerProcess(executable: $0, logURL: logURL) }
    }

    public var recommendedModelID: String {
        ModelCatalog.recommendedID(isAppleSilicon: hardware.isAppleSilicon, memoryGB: hardware.memoryGB)
    }

    public var selectedModel: ModelInfo? { catalog.first { $0.id == selectedModelID } ?? importedModel }

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
        m.family == "custom" ? FileManager.default.fileExists(atPath: store.localURL(for: m).path) : store.isInstalled(m)
    }

    // MARK: Engine

    public func startEngine() async {
        await pushToneDefinitions()
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
            let provider = try await server.start(.init(modelPath: store.localURL(for: model)))
            await correction.setProvider(provider)
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

    public func select(_ model: ModelInfo) {
        selectedModelID = model.id
        Task { await startEngine() }
    }

    private func pushToneDefinitions() async {
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
