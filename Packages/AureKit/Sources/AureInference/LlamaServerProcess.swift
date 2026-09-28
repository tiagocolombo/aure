import AureCore
import Darwin
import Foundation

/// Launches and supervises a local `llama-server` process bound to 127.0.0.1
/// on a random free port with a random API key.
public actor LlamaServerProcess {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready(port: Int)
        case failed(String)
    }

    public struct Config: Sendable, Equatable {
        public var modelPath: URL
        /// Context per request (tokens). Each parallel slot gets this much.
        public var contextSize: Int = 4096
        /// nil = automatic (all layers on Apple Silicon, 0 on Intel).
        public var gpuLayers: Int?
        /// nil = automatic (physical cores).
        public var threads: Int?
        /// Requests the server can work on at once (paragraphs of a long email).
        /// nil = automatic (`Hardware.recommendedParallelSlots`).
        public var parallel: Int?

        public init(modelPath: URL, contextSize: Int = 4096, gpuLayers: Int? = nil, threads: Int? = nil,
                    parallel: Int? = nil) {
            self.modelPath = modelPath
            self.contextSize = contextSize
            self.gpuLayers = gpuLayers
            self.threads = threads
            self.parallel = parallel
        }
    }

    public private(set) var state: State = .stopped
    public private(set) var config: Config?
    private var process: ChildProcess?
    private var apiKey = ""
    private var restarts: [Date] = []
    private var stopping = false
    private let executable: URL
    private let logURL: URL?

    public init(executable: URL, logURL: URL? = nil) {
        self.executable = executable
        self.logURL = logURL
    }

    /// Finds llama-server. A packaged app only ever runs the helper in its own
    /// bundle, signed like the app: an environment variable or PATH entry would let
    /// any program choose what Aure launches. Debug builds also honour
    /// AURE_LLAMA_SERVER, the folder of the running executable and PATH.
    public static func locateExecutable() -> URL? {
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server")
        #if DEBUG
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["AURE_LLAMA_SERVER"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        candidates.append(bundled)
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("llama-server"))
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("llama-server"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
        #else
        guard fm.isExecutableFile(atPath: bundled.path) else { return nil }
        guard CodeSignature.matchesOwnSigner(bundled) else {
            Log.info("llama-server: bundled helper is not signed like the app; not starting it")
            return nil
        }
        return bundled
        #endif
    }

    public var provider: LlamaServerProvider? {
        guard case let .ready(port) = state else { return nil }
        return LlamaServerProvider(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: apiKey)
    }

    /// Starts (or restarts with a new config) and waits until /health is OK.
    @discardableResult
    public func start(_ config: Config, timeout: TimeInterval = 180) async throws -> LlamaServerProvider {
        if self.config == config, let p = provider { return p }
        await stop()
        stopping = false
        self.config = config
        return try await launch(timeout: timeout)
    }

    private func launch(timeout: TimeInterval) async throws -> LlamaServerProvider {
        guard let config else { throw AureError.modelNotLoaded }
        state = .starting
        for pid in LocalListener.orphans(of: executable) {
            Log.info("llama-server: stopping a copy left running by an earlier Aure (pid \(pid))")
            kill(pid, SIGTERM)
        }
        let port = Self.freePort()
        apiKey = UUID().uuidString
        let hw = Hardware.current
        let slots = max(1, config.parallel ?? hw.recommendedParallelSlots)

        // The key goes in a file only this user can read: arguments are visible to
        // every account on the Mac (`ps`).
        let keyFile = try Self.writeKeyFile(apiKey)
        defer { try? FileManager.default.removeItem(at: keyFile) }
        let arguments = [
            "-m", config.modelPath.path,
            "--host", "127.0.0.1", "--port", String(port),
            "--api-key-file", keyFile.path,
            "-c", String(config.contextSize * slots),
            "-ngl", String(config.gpuLayers ?? (hw.isAppleSilicon ? 99 : 0)),
            "-t", String(config.threads ?? hw.performanceCores),
            "--jinja",
            "--no-webui",
            // /slots returns each slot's full prompt, i.e. the user's text.
            "--no-slots",
            "-np", String(slots),
        ]
        var log: FileHandle?
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            log = try? FileHandle(forWritingTo: logURL)
        }
        defer { try? log?.close() }
        if !HelperSandbox.isAvailable { Log.info("llama-server: sandbox-exec missing; running unsandboxed") }
        let p: ChildProcess
        do {
            p = try ChildProcess(
                executable: executable, arguments: arguments, environment: ChildProcess.minimalEnvironment(),
                output: log,
                sandboxProfile: HelperSandbox.isAvailable ? HelperSandbox.profile : nil,
                sandboxParameters: HelperSandbox.parameters(helper: executable, model: config.modelPath)
            ) { [weak self] code in
                guard let self else { return }
                Task { await self.processExited(code: code) }
            }
        } catch {
            state = .failed("could not start llama-server: \(error.localizedDescription)")
            throw AureError.server("could not start llama-server")
        }
        process = p

        let deadline = Date().addingTimeInterval(timeout)
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        while Date() < deadline {
            if !p.isRunning {
                state = .failed("llama-server exited (code \(p.terminationStatus ?? -1)); see log")
                throw AureError.server("llama-server exited while loading the model")
            }
            var req = URLRequest(url: health)
            req.timeoutInterval = 2
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                // /health needs no key, so anything on the port answers it. Only trust
                // the port if our own child is the one listening on it.
                guard LocalListener.ports(of: p.pid).contains(port) else {
                    p.terminate()
                    state = .failed("another program is using llama-server's port")
                    throw AureError.server("another program is using llama-server's port")
                }
                state = .ready(port: port)
                return LlamaServerProvider(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: apiKey)
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        p.terminate()
        state = .failed("timed out loading the model")
        throw AureError.server("timed out loading the model")
    }

    /// Only the current process restarts: an old one exiting after a restart finds `process` running.
    private func processExited(code: Int32) async {
        guard let proc = process, !proc.isRunning, !stopping else { return }
        process = nil
        // Restart with backoff, at most 3 times per minute.
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard restarts.count <= 3 else {
            state = .failed("llama-server keeps crashing (code \(code))")
            return
        }
        state = .starting
        try? await Task.sleep(for: .seconds(Double(restarts.count)))
        _ = try? await launch(timeout: 180)
    }

    public func stop() async {
        stopping = true
        if let p = process, p.isRunning {
            p.terminate()
            for _ in 0..<50 where p.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if p.isRunning { p.forceKill() }
        }
        process = nil
        state = .stopped
    }

    public var pid: Int32? { process?.pid }

    /// A new file in the per-user temporary folder (mode 0700), readable only by this user.
    static func writeKeyFile(_ key: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aure-\(UUID().uuidString).key")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AureError.server("could not create llama-server's key file") }
        defer { close(fd) }
        let data = Array((key + "\n").utf8)
        guard write(fd, data, data.count) == data.count else { throw AureError.server("could not write llama-server's key file") }
        return url
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        return port == 0 ? Int.random(in: 49152...65000) : port
    }
}
