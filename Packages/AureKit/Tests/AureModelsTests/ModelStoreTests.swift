import CryptoKit
import Foundation
import Testing
@testable import AureModels

/// Serves a fixed payload, honoring Range requests.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var lastRange: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = Self.payload
        var status = 200
        Self.lastRange = request.value(forHTTPHeaderField: "Range")
        if let range = Self.lastRange, let start = Int(range.dropFirst(6).dropLast()) {
            body = body.subdata(in: start..<body.count)
            status = 206
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ModelStoreTests {
    func makeStore() -> (ModelStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aure-models-\(UUID().uuidString)")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return (ModelStore(directory: dir, session: URLSession(configuration: cfg)), dir)
    }

    func model(for data: Data, sha: String? = nil) -> ModelInfo {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelInfo(id: "t", name: "T", repo: "r", file: "t.gguf", family: "qwen3", summary: "", minRAMGB: 1,
                         license: "x", bytes: Int64(data.count), sha256: sha ?? digest,
                         url: URL(string: "https://example.invalid/t.gguf")!)
    }

    @Test func catalogHasFourModelsWithHashes() {
        let c = ModelCatalog.load()
        #expect(c.map(\.id) == ["qwen3-4b", "qwen3-1.7b", "qwen3.5-4b", "qwen3-0.6b"])
        #expect(c.allSatisfy { $0.sha256.count == 64 && $0.bytes > 400_000_000 })
    }

    @Test func recommendation() {
        #expect(ModelCatalog.recommendedID(isAppleSilicon: false, memoryGB: 16) == "qwen3-4b")
        #expect(ModelCatalog.recommendedID(isAppleSilicon: true, memoryGB: 8) == "qwen3-1.7b")
        let big = ModelCatalog.load().first { $0.id == "qwen3-4b" }!
        #expect(ModelCatalog.fit(big, isAppleSilicon: true, memoryGB: 4).ok == false)
    }

    @Test func downloadVerifiesAndInstalls() async throws {
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        StubProtocol.payload = data
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(for: data)
        let url = try await store.download(m) { _ in }
        #expect(store.isInstalled(m))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func resumesFromPartialFile() async throws {
        let data = Data((0..<2_500_000).map { UInt8($0 % 13) })
        StubProtocol.payload = data
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(for: data)
        try data.prefix(1_000_000).write(to: store.partialURL(for: m))
        _ = try await store.download(m) { _ in }
        #expect(StubProtocol.lastRange == "bytes=1000000-")
        #expect(store.isInstalled(m))
    }

    @Test func badChecksumDeletesFile() async throws {
        let data = Data(repeating: 7, count: 100_000)
        StubProtocol.payload = data
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(for: data, sha: String(repeating: "0", count: 64))
        await #expect(throws: ModelError.checksumMismatch) { _ = try await store.download(m) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: m).path))
        #expect(!store.isInstalled(m))
    }

    @Test func importAndDelete() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("my-model-\(UUID().uuidString).gguf")
        try Data([1, 2, 3]).write(to: src)
        _ = try store.importModel(from: src)
        #expect(store.importedModels(catalog: []).map(\.lastPathComponent) == [src.lastPathComponent])
    }
}

@Suite struct OllamaNameTests {
    @Test func catalogModelsMapToHuggingFacePulls() {
        let names = ModelCatalog.load().map(\.ollamaName)
        #expect(names.contains("hf.co/Qwen/Qwen3-4B-GGUF:Q4_K_M"))
        #expect(names.contains("hf.co/bartowski/Qwen_Qwen3-0.6B-GGUF:Q4_K_M"))
        #expect(!names.contains(nil))
    }

    @Test func importedFilesHaveNoOllamaName() {
        let m = ModelInfo(id: "file:x.gguf", name: "x", repo: "", file: "x.gguf", family: "custom", summary: "",
                          minRAMGB: 0, license: "", bytes: 0, sha256: "", url: URL(fileURLWithPath: "/tmp/x.gguf"))
        #expect(m.ollamaName == nil)
    }
}
