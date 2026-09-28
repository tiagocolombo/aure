import CryptoKit
import Foundation

public struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var repo: String
    public var file: String
    public var family: String
    public var summary: String
    public var minRAMGB: Double
    public var license: String
    public var bytes: Int64
    public var sha256: String
    public var url: URL

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public init(id: String, name: String, repo: String, file: String, family: String, summary: String,
                minRAMGB: Double, license: String, bytes: Int64, sha256: String, url: URL) {
        self.id = id; self.name = name; self.repo = repo; self.file = file; self.family = family
        self.summary = summary; self.minRAMGB = minRAMGB; self.license = license; self.bytes = bytes
        self.sha256 = sha256; self.url = url
    }

    /// The same weights pulled through Ollama: "hf.co/<repo>:<quant>", e.g.
    /// "hf.co/Qwen/Qwen3-4B-GGUF:Q4_K_M". Nil for models not from Hugging Face.
    public var ollamaName: String? {
        guard !repo.isEmpty, file.lowercased().hasSuffix(".gguf"),
              let quant = file.dropLast(5).split(separator: "-").last, quant.first?.isLetter == true else { return nil }
        return "hf.co/\(repo):\(quant)"
    }
}

public enum ModelCatalog {
    /// SwiftPM's generated `Bundle.module` looks next to the .app bundle root
    /// and crashes when the resource bundle is (correctly) in
    /// Contents/Resources, so look there first.
    static var resourceBundle: Bundle {
        let name = "AureKit_AureModels.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()] {
            if let url = base?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        }
        return Bundle.module
    }

    public static func load() -> [ModelInfo] {
        let bundle = resourceBundle
        guard let url = bundle.url(forResource: "models", withExtension: "json", subdirectory: "Resources")
            ?? bundle.url(forResource: "models", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let models = try? JSONDecoder().decode([ModelInfo].self, from: data)
        else { return [] }
        return models
    }

    /// Default model for this machine.
    /// Based on docs/MODEL_EVAL.md: accuracy first, as long as the Mac has room.
    public static func recommendedID(isAppleSilicon: Bool, memoryGB: Double) -> String {
        if memoryGB >= 12 { return "qwen3-4b" }
        if memoryGB >= 6 { return "qwen3-1.7b" }
        return "qwen3-0.6b"
    }

    /// Whether a model is sensible on this machine, with a reason if not.
    public static func fit(_ m: ModelInfo, isAppleSilicon: Bool, memoryGB: Double) -> (ok: Bool, note: String?) {
        if memoryGB < m.minRAMGB {
            return (false, "Needs \(Int(m.minRAMGB)) GB of memory")
        }
        if !isAppleSilicon && m.bytes > 2_800_000_000 {
            return (true, "Slow on Intel Macs")
        }
        return (true, nil)
    }
}

public enum ModelError: Error, LocalizedError, Equatable {
    case notEnoughDiskSpace(needed: Int64)
    case checksumMismatch
    case httpStatus(Int)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notEnoughDiskSpace(let n):
            "Not enough disk space (needs \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)))."
        case .checksumMismatch: "The download was corrupted (checksum mismatch). Please try again."
        case .httpStatus(let c): "Download failed (HTTP \(c))."
        case .notFound: "Model file not found."
        }
    }
}

/// Downloads, verifies, lists, imports and deletes GGUF models under
/// ~/Library/Application Support/Aure/Models.
public final class ModelStore: @unchecked Sendable {
    public let directory: URL
    let session: URLSession

    public init(directory: URL = ModelStore.defaultDirectory, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aure/Models", isDirectory: true)
    }

    public func localURL(for m: ModelInfo) -> URL { directory.appendingPathComponent(m.file) }

    public func isInstalled(_ m: ModelInfo) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localURL(for: m).path),
              let size = attrs[.size] as? Int64 else { return false }
        return size == m.bytes
    }

    /// User-imported GGUF files that are not in the catalog.
    public func importedModels(catalog: [ModelInfo]) -> [URL] {
        let known = Set(catalog.map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" && !known.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func importModel(from source: URL) throws -> URL {
        let dest = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    public func delete(_ m: ModelInfo) throws {
        let url = localURL(for: m)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: partialURL(for: m))
    }

    func partialURL(for m: ModelInfo) -> URL { directory.appendingPathComponent(m.file + ".part") }

    public func freeDiskSpace() -> Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    /// Downloads with resume support (HTTP Range on a `.part` file) and
    /// verifies sha256. `progress` receives values in 0...1.
    public func download(_ m: ModelInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let final = localURL(for: m)
        if isInstalled(m) { return final }

        let part = partialURL(for: m)
        let fm = FileManager.default
        var have: Int64 = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        if have > m.bytes { try? fm.removeItem(at: part); have = 0 }
        if freeDiskSpace() < (m.bytes - have) + 200_000_000 {
            throw ModelError.notEnoughDiskSpace(needed: m.bytes - have)
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        var req = URLRequest(url: m.url)
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let (bytes, resp) = try await session.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else { throw ModelError.httpStatus(status) }
        if status == 200 && have > 0 {
            // Server ignored Range: start over.
            try Data().write(to: part)
            have = 0
        }

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = have
        var lastReport = Date.distantPast
        progress(Double(written) / Double(m.bytes))
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    progress(min(0.999, Double(written) / Double(m.bytes)))
                    lastReport = Date()
                }
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()

        guard try Self.sha256(of: part) == m.sha256.lowercased() else {
            try? fm.removeItem(at: part)
            throw ModelError.checksumMismatch
        }
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: part, to: final)
        progress(1)
        return final
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
