import Foundation
import Testing
@testable import AureModels

/// Builds a GGUF header with string keys, padded (sparsely) to `size` bytes.
func fakeGGUF(at url: URL, arch: String, name: String?, size: Int64 = 60_000_000) throws {
    var d = Data("GGUF".utf8)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func str(_ s: String) { u64(UInt64(s.utf8.count)); d.append(contentsOf: Array(s.utf8)) }
    var kv: [(String, String)] = [("general.architecture", arch)]
    if let name { kv.append(("general.name", name)) }
    u32(3); u64(0); u64(UInt64(kv.count + 1))
    str("general.alignment"); u32(4); u32(32)          // a scalar before the strings
    for (k, v) in kv { str(k); u32(8); str(v) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try d.write(to: url)
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: UInt64(size)) // sparse: no real disk use
    try h.close()
}

@Suite struct ExternalModelsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aure-ext-\(UUID().uuidString)")

    @Test func readsNameAndArchitectureFromHeader() throws {
        let f = root.appendingPathComponent("m.gguf")
        try fakeGGUF(at: f, arch: "qwen3", name: "Qwen3 8B Instruct")
        let info = try #require(GGUFHeader.read(f))
        #expect(info.architecture == "qwen3")
        #expect(info.name == "Qwen3 8B Instruct")
        #expect(GGUFHeader.parse(Data("nope".utf8)) == nil)
    }

    @Test func findsLMStudioAndHuggingFaceModelsAndSkipsNonChatFiles() throws {
        let lm = root.appendingPathComponent("lmstudio")
        try fakeGGUF(at: lm.appendingPathComponent("lmstudio-community/Llama-3.2-3B/Llama-3.2-3B-Q4_K_M.gguf"), arch: "llama", name: "Llama 3.2 3B")
        try fakeGGUF(at: lm.appendingPathComponent("x/mmproj-model-f16.gguf"), arch: "clip", name: "proj")
        try fakeGGUF(at: lm.appendingPathComponent("x/nomic-embed.gguf"), arch: "nomic-bert", name: "Embed")
        try fakeGGUF(at: lm.appendingPathComponent("x/tiny.gguf"), arch: "llama", name: "Tiny", size: 1_000)
        // Hugging Face cache: snapshot entries are symlinks to blobs.
        let hf = root.appendingPathComponent("hf")
        let blob = hf.appendingPathComponent("models--Qwen--Qwen3-8B-GGUF/blobs/abc123")
        try fakeGGUF(at: blob, arch: "qwen3", name: nil)
        let link = hf.appendingPathComponent("models--Qwen--Qwen3-8B-GGUF/snapshots/main/Qwen3-8B-Q4_K_M.gguf")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)

        let found = ExternalModels.scan([.init(source: "LM Studio", directory: lm), .init(source: "Hugging Face", directory: hf)])
        #expect(found.map(\.name) == ["Qwen3-8B-Q4_K_M", "Llama 3.2 3B"])
        #expect(found.map(\.source) == ["Hugging Face", "LM Studio"])
        #expect(found[0].id.hasPrefix(ExternalModels.idPrefix))
        #expect(found[0].info.family == ExternalModels.family)
    }

    @Test func findsOllamaModelsThroughManifests() throws {
        let ol = root.appendingPathComponent("ollama")
        try fakeGGUF(at: ol.appendingPathComponent("blobs/sha256-deadbeef"), arch: "gemma3", name: "gemma")
        let manifest = ol.appendingPathComponent("manifests/registry.ollama.ai/library/gemma3/4b")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:deadbeef"}]}"#.utf8).write(to: manifest)

        let found = ExternalModels.scan([.init(source: "Ollama", directory: ol, isOllama: true)])
        #expect(found.map(\.name) == ["gemma3:4b"])
    }

    @Test func listsSplitModelsOnceAndSkipsAuresOwnFolder() throws {
        let dir = root.appendingPathComponent("split")
        for i in 1...2 {
            try fakeGGUF(at: dir.appendingPathComponent(String(format: "Big-%05d-of-00002.gguf", i)), arch: "llama", name: "Big")
        }
        let own = root.appendingPathComponent("aure")
        try fakeGGUF(at: own.appendingPathComponent("Qwen3-4B.gguf"), arch: "qwen3", name: "Qwen3 4B")

        let found = ExternalModels.scan([.init(source: "llama.cpp", directory: root)], exclude: own)
        #expect(found.map(\.name) == ["Big"])
        #expect(found.first?.bytes == 120_000_000)
    }

    @Test func missingFoldersAreFine() {
        #expect(ExternalModels.scan([.init(source: "LM Studio", directory: root.appendingPathComponent("none"))]).isEmpty)
    }

    @Test func matchesTheSameFileThroughASymlinkedPath() throws {
        let real = root.appendingPathComponent("real/m.gguf")
        try fakeGGUF(at: real, arch: "llama", name: "M")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real.deletingLastPathComponent())
        let m = ExternalModel(url: real, name: "M", source: "LM Studio", bytes: 1, architecture: nil)
        #expect(m.matches(ExternalModels.idPrefix + alias.appendingPathComponent("m.gguf").path))
        #expect(!m.matches("qwen3-4b"))
        #expect(!m.matches(nil))
    }
}
