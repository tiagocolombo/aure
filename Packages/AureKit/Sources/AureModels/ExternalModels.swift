import Foundation

/// A GGUF model another local-LLM tool already downloaded. Aure uses it in place
/// (no copy); it is only read, never moved or deleted.
public struct ExternalModel: Identifiable, Hashable, Sendable {
    /// "path:<absolute path>", stable across launches.
    public var id: String { ExternalModels.idPrefix + url.path }
    public var url: URL
    /// Display name from the GGUF metadata (`general.name`), else the file name.
    public var name: String
    /// Which tool downloaded it ("LM Studio", "Ollama", ...).
    public var source: String
    public var bytes: Int64
    /// `general.architecture`, e.g. "qwen3", "llama".
    public var architecture: String?

    public init(url: URL, name: String, source: String, bytes: Int64, architecture: String?) {
        self.url = url; self.name = name; self.source = source; self.bytes = bytes; self.architecture = architecture
    }

    public var info: ModelInfo {
        ModelInfo(id: id, name: name, repo: "", file: url.lastPathComponent, family: ExternalModels.family,
                  summary: source, minRAMGB: 0, license: "", bytes: bytes, sha256: "", url: url)
    }

    /// True when `id` points at this file, even through a different symlinked path.
    public func matches(_ id: String?) -> Bool {
        guard let id, id.hasPrefix(ExternalModels.idPrefix) else { return false }
        if id == self.id { return true }
        let other = URL(fileURLWithPath: String(id.dropFirst(ExternalModels.idPrefix.count)))
        return other.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
    }
}

/// Finds GGUF models downloaded by other llama.cpp-based tools.
public enum ExternalModels {
    public static let idPrefix = "path:"
    public static let family = "external"

    /// Files smaller than this are vocab/test files, not chat models.
    static let minimumBytes: Int64 = 50_000_000
    /// Architectures that cannot answer chat prompts (embeddings, vision/audio encoders).
    static let nonChatArchitectures: Set<String> = [
        "bert", "nomic-bert", "nomic-bert-moe", "jina-bert-v2", "jina-bert-v3", "neo-bert", "modern-bert",
        "t5encoder", "clip", "wavtokenizer-dec",
    ]

    public struct Location: Sendable {
        public var source: String
        public var directory: URL
        /// Ollama keeps weights as content-addressed blobs listed in manifests.
        public var isOllama = false
    }

    /// Default download folders, honouring each tool's override variable.
    public static func defaultLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [Location] {
        func path(_ p: String) -> URL { home.appendingPathComponent(p, isDirectory: true) }
        let appSupport = path("Library/Application Support")
        var out: [Location] = [
            Location(source: "LM Studio", directory: path(".lmstudio/models")),
            Location(source: "LM Studio", directory: path(".cache/lm-studio/models")),
            Location(source: "Ollama", directory: environment["OLLAMA_MODELS"].map { URL(fileURLWithPath: $0) }
                ?? path(".ollama/models"), isOllama: true),
            Location(source: "llama.cpp", directory: environment["LLAMA_CACHE"].map { URL(fileURLWithPath: $0) }
                ?? path("Library/Caches/llama.cpp")),
            Location(source: "Hugging Face", directory: (environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
                ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
                ?? path(".cache/huggingface/hub"))),
            Location(source: "Jan", directory: appSupport.appendingPathComponent("Jan")),
            Location(source: "Jan", directory: path("jan/models")),
            Location(source: "GPT4All", directory: appSupport.appendingPathComponent("nomic.ai/GPT4All")),
        ]
        if let extra = environment["AURE_EXTRA_MODEL_DIRS"] {
            out += extra.split(separator: ":").map { Location(source: "Custom folder", directory: URL(fileURLWithPath: String($0))) }
        }
        return out
    }

    /// Scans the locations (a few directory walks and header reads; call off the main thread).
    /// `exclude` skips Aure's own models folder.
    public static func scan(_ locations: [Location] = defaultLocations(), exclude: URL? = nil) -> [ExternalModel] {
        var seen = Set<String>()
        let excluded = exclude?.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [ExternalModel] = []
        for loc in locations {
            let candidates = loc.isOllama ? ollamaModels(in: loc.directory) : ggufFiles(in: loc.directory).map { ($0, nil as String?) }
            for (url, label) in candidates {
                let real = url.resolvingSymlinksInPath().standardizedFileURL
                if let excluded, real.path.hasPrefix(excluded + "/") { continue }
                guard seen.insert(real.path).inserted, let m = model(at: url, real: real, source: loc.source, label: label) else { continue }
                out.append(m)
            }
        }
        return out.sorted { ($0.source, $0.name.lowercased()) < ($1.source, $1.name.lowercased()) }
    }

    /// Builds the model entry for one file, or nil if it is not a usable chat model.
    static func model(at url: URL, real: URL, source: String, label: String?) -> ExternalModel? {
        let name = url.lastPathComponent.lowercased()
        // Multimodal projectors are companions of a model, not models.
        if name.contains("mmproj") { return nil }
        // Split models: list the first part only, sized as the sum of all parts.
        var bytes = fileSize(real)
        if let parts = splitParts(of: real) {
            guard parts.first == real else { return nil }
            bytes = parts.reduce(0) { $0 + fileSize($1) }
        }
        guard bytes >= minimumBytes, let header = GGUFHeader.read(real) else { return nil }
        if let arch = header.architecture, nonChatArchitectures.contains(arch) { return nil }
        let display = label ?? header.name.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        return ExternalModel(url: url, name: display, source: source, bytes: bytes, architecture: header.architecture)
    }

    /// Every *.gguf below `dir` (following the symlinks Hugging Face uses), at most 8 levels deep.
    static func ggufFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            if e.level > 8 { e.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "gguf" else { continue }
            out.append(url)
        }
        return out
    }

    /// Ollama: manifests/<registry>/<namespace>/<model>/<tag> → blobs/sha256-<digest>.
    static func ollamaModels(in dir: URL) -> [(URL, String?)] {
        let manifests = dir.appendingPathComponent("manifests")
        guard let e = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, String?)] = []
        for case let file as URL in e {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = json["layers"] as? [[String: Any]],
                  let digest = layers.first(where: { $0["mediaType"] as? String == "application/vnd.ollama.image.model" })?["digest"] as? String,
                  isOllamaDigest(digest)
            else { continue }
            let blob = dir.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
            // ".../library/qwen3/4b" → "qwen3:4b" (the name users type in `ollama run`).
            let parts = file.pathComponents
            let label = parts.count >= 2 ? "\(parts[parts.count - 2]):\(parts[parts.count - 1])" : nil
            out.append((blob, label))
        }
        return out
    }

    /// "sha256:<64 hex>". Anything else could point the blob path outside `blobs/`.
    static func isOllamaDigest(_ digest: String) -> Bool {
        digest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    /// True when `url` is a model file inside one of `locations`: a GGUF file, or a
    /// blob in an Ollama models folder. The path itself is checked, not where its
    /// symlinks lead, as Hugging Face snapshots are symlinks.
    public static func isInKnownLocation(_ url: URL, locations: [Location] = defaultLocations()) -> Bool {
        let path = url.standardizedFileURL.path
        return locations.contains { loc in
            let dir = loc.directory.standardizedFileURL.path
            if loc.isOllama {
                return path.hasPrefix(dir + "/blobs/sha256-") && !path.dropFirst(dir.count + 7).contains("/")
            }
            return path.hasPrefix(dir + "/") && url.pathExtension.lowercased() == "gguf"
        }
    }

    /// "model-00001-of-00003.gguf" → all parts in order, or nil if not a split model.
    static func splitParts(of url: URL) -> [URL]? {
        let name = url.lastPathComponent
        guard let re = try? NSRegularExpression(pattern: #"^(.*)-(\d{5})-of-(\d{5})\.gguf$"#, options: [.caseInsensitive]),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let prefixRange = Range(m.range(at: 1), in: name), let totalRange = Range(m.range(at: 3), in: name),
              let total = Int(name[totalRange]), total > 1 else { return nil }
        let prefix = name[prefixRange]
        let dir = url.deletingLastPathComponent()
        return (1...total).map { dir.appendingPathComponent(String(format: "%@-%05d-of-%05d.gguf", String(prefix), $0, total)) }
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

/// Reads `general.architecture` and `general.name` from a GGUF header
/// (they come first in practice; stops at the first array or after 1 MB).
enum GGUFHeader {
    struct Info { var architecture: String?; var name: String? }

    static func read(_ url: URL) -> Info? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 1 << 20) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Info? {
        var r = Reader(data: data)
        guard r.bytes(4) == Data("GGUF".utf8), let version = r.u32(), version >= 2,
              r.u64() != nil, let kvCount = r.u64() else { return nil }
        var info = Info()
        for _ in 0..<min(kvCount, 256) {
            guard let key = r.string(), let type = r.u32() else { break }
            if type == 8 { // string
                guard let value = r.string() else { break }
                if key == "general.architecture" { info.architecture = value }
                if key == "general.name" { info.name = value }
            } else if let size = scalarSize(type) {
                guard r.skip(size) else { break }
            } else {
                break // arrays (tokenizer data) come after the general.* keys
            }
            if info.architecture != nil && info.name != nil { break }
        }
        return info
    }

    /// Byte sizes of GGUF scalar value types.
    static func scalarSize(_ type: UInt32) -> Int? {
        switch type {
        case 0, 1, 7: 1   // u8, i8, bool
        case 2, 3: 2      // u16, i16
        case 4, 5, 6: 4   // u32, i32, f32
        case 10, 11, 12: 8 // u64, i64, f64
        default: nil
        }
    }

    struct Reader {
        let data: Data
        var offset = 0
        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + n)
        }
        mutating func skip(_ n: Int) -> Bool { bytes(n) != nil }
        mutating func u32() -> UInt32? { bytes(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian } }
        mutating func u64() -> UInt64? { bytes(8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian } }
        mutating func string() -> String? {
            guard let n = u64(), n <= 65_536, let b = bytes(Int(n)) else { return nil }
            return String(decoding: b, as: UTF8.self)
        }
    }
}
