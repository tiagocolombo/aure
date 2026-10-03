import AureCore
import AureInference
import Foundation

// aure-eval: run golden cases through the real correction pipeline.
//
//   swift run aure-eval --server http://127.0.0.1:18080 [--set eval/golden] [--limit N] [--verbose]
//                       [--ollama qwen3:4b]              (use a local Ollama model instead of --server)
//                       [--prompt aure|grammarlyAPIO|minimalTaxonomy]
//                       [--thresholds 0,0.5,0.7,0.9]     (one model call per case, scored at each threshold)
//                       [--out results.jsonl]            (full per-case output, for eval/score_long.py)
//                       [--parallel N]                   (paragraphs checked at once; server needs -np N)
//   swift run aure-eval --detect eval/detection/detection.jsonl   (language detection, no model)
//
// Each JSONL line: {"text": "...", "tone": "formal", "dialect": "en_US",
//                   "expect": ["acceptable output", ...] | null (= must stay unchanged),
//                   "mode": "correct"}
//
// Rewrite cases (eval/rewrite): {"mode": "rewrite", "text": "...", "tone": "formal",
//                   "kind": "improve" | "good",   (good = no alternative should be offered)
//                   "keep": ["facts", "names", "numbers that must survive"]}
// Scored as the app shows them: an alternative is offered only when WritingSuggestion accepts it.

struct Case: Decodable {
    var text: String
    var tone: Tone?
    var dialect: Dialect?
    var mode: CheckMode?
    var expect: [String]?
    var note: String?
    var kind: String?
    var keep: [String]?
}

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

// --detect FILE: language detection only, no model (see Detection.swift).
if let path = arg("--detect") {
    try runDetection(path)
    exit(0)
}

let server = arg("--server") ?? "http://127.0.0.1:18080"
let setPath = arg("--set") ?? "eval/golden"
let limit = Int(arg("--limit") ?? "") ?? .max
let verbose = CommandLine.arguments.contains("--verbose")
let promptStyle = PromptStyle(rawValue: arg("--prompt") ?? "aure") ?? .aure
let thresholds = (arg("--thresholds") ?? "0").split(separator: ",").compactMap { Double($0) }
let outPath = arg("--out")
var outLines: [String] = []

var files: [URL] = []
var isDir: ObjCBool = false
if FileManager.default.fileExists(atPath: setPath, isDirectory: &isDir), isDir.boolValue {
    files = (try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: setPath), includingPropertiesForKeys: nil))
        .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
} else {
    files = [URL(fileURLWithPath: setPath)]
}

var cases: [(String, Case)] = []
for f in files {
    for line in try String(contentsOf: f, encoding: .utf8).split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        cases.append((f.lastPathComponent, try JSONDecoder().decode(Case.self, from: Data(line.utf8))))
    }
}
cases = Array(cases.prefix(limit))

func norm(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
}

let provider: any LLMProvider = if let model = arg("--ollama") {
    try await OllamaClient().provider(for: model)
} else {
    LlamaServerProvider(baseURL: URL(string: server)!, apiKey: ProcessInfo.processInfo.environment["AURE_API_KEY"])
}

// --raw N: print the model's raw answer for case N (0-based) and exit.
if let n = Int(arg("--raw") ?? ""), n < cases.count {
    let c = cases[n].1
    let req = CheckRequest(text: c.text, tone: c.tone ?? .formal, mode: c.mode ?? .correct, dialect: c.dialect ?? .enUS)
    let prompt = PromptBuilder.build(req, promptStyle: promptStyle)
    let out = try await provider.generate(system: prompt.system, examples: prompt.examples, user: prompt.user,
                                          jsonSchema: nil,
                                          params: GenParams(temperature: prompt.temperature, maxTokens: prompt.maxTokens))
    print("max_tokens \(prompt.maxTokens), generated \(out.tokens.count) tokens\n---\n\(out.text)\n---")
    exit(0)
}
let service = CorrectionService(provider: provider)
await service.setPromptStyle(promptStyle)
// --parallel N: paragraphs of a long text sent at once (match the server's -np).
await service.setMaxParallel(Int(arg("--parallel") ?? "") ?? 1)

struct Score {
    var exact = 0, fixedSome = 0, cleanKept = 0, cleanTotal = 0, errTotal = 0, falseAlarm = 0
}
var scores = [Score](repeating: Score(), count: thresholds.count)
var rejected = 0
var latencies: [Int] = []

struct RewriteScore {
    var improveTotal = 0, offered = 0, goodTotal = 0, goodLeftAlone = 0
    var offeredTotal = 0, factsKept = 0, lengthRatios: [Double] = []
}
var rw = RewriteScore()
var sawRewrite = false
func words(_ s: String) -> Int { s.split { $0.isWhitespace }.count }

for (file, c) in cases {
    let req = CheckRequest(text: c.text, tone: c.tone ?? .formal, mode: c.mode ?? .correct, dialect: c.dialect ?? .enUS)
    let started = Date()
    var result: CheckResult?
    var status = ""
    do {
        result = try await service.check(req)
    } catch {
        rejected += 1
        status = " [\(error.localizedDescription)]"
    }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    latencies.append(ms)
    if outPath != nil {
        let row: [String: Any] = [
            "text": c.text, "output": result?.corrected ?? c.text, "latency_ms": ms,
            "error": status.isEmpty ? NSNull() : status as Any,
            "issues": (result?.issues ?? []).map {
                ["original": $0.original, "replacement": $0.replacement, "confidence": $0.confidence,
                 "category": $0.category.rawValue] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        outLines.append(String(decoding: data, as: UTF8.self))
    }

    if req.mode == .rewrite {
        sawRewrite = true
        let suggestion = result.flatMap { WritingSuggestion(original: c.text, replacement: $0.corrected, tone: req.tone) }
        let isGood = c.kind == "good"
        if isGood { rw.goodTotal += 1; if suggestion == nil { rw.goodLeftAlone += 1 } }
        else { rw.improveTotal += 1; if suggestion != nil { rw.offered += 1 } }
        var mark = isGood ? (suggestion == nil ? "✔" : "✘") : (suggestion != nil ? "✔" : "✘")
        if let s = suggestion {
            rw.offeredTotal += 1
            var missing = (c.keep ?? []).filter { !s.replacement.localizedCaseInsensitiveContains($0) }
            // A template placeholder ("Dear [Name]") is invented content, never acceptable.
            if s.replacement.contains("[") && !c.text.contains("[") { missing.append("(added a [placeholder])") }
            // A rewrite must stay in the text's language (e.g. never translate Portuguese to English).
            let language = DialectDetector.detect(s.replacement, fallback: req.dialect)
            if language.detected, language.dialect.language != req.dialect.language { missing.append("(changed language)") }
            if missing.isEmpty { rw.factsKept += 1 } else { mark = "✘" }
            rw.lengthRatios.append(Double(words(s.replacement)) / Double(max(1, words(c.text))))
            print("\(mark) [\(req.tone.rawValue)/\(c.kind ?? "improve")] \(c.text)\n    → \(s.replacement)"
                  + (missing.isEmpty ? "" : "\n    LOST: \(missing.joined(separator: ", "))"))
        } else {
            print("\(mark) [\(req.tone.rawValue)/\(c.kind ?? "improve")] \(c.text)\n    → (no alternative)\(status)")
        }
        continue
    }

    let expects = c.expect ?? [c.text]
    let isClean = c.expect == nil
    for (k, t) in thresholds.enumerated() {
        let kept = (result?.issues ?? []).filter { $0.confidence >= t }
        let out = CorrectionService.applying(kept, to: c.text)
        let ok = expects.map(norm).contains(norm(out))
        if isClean {
            scores[k].cleanTotal += 1
            if norm(out) == norm(c.text) { scores[k].cleanKept += 1 } else { scores[k].falseAlarm += 1 }
        } else {
            scores[k].errTotal += 1
            if ok { scores[k].exact += 1 }
            if norm(out) != norm(c.text) { scores[k].fixedSome += 1 }
        }
        if k == 0, verbose || !ok {
            print("\(ok ? "✔" : "✘") [\(file)] \(c.text)\n    → \(out)\(status)")
            for i in result?.issues ?? [] {
                print(String(format: "      %.2f  \"%@\" → \"%@\"", i.confidence, i.original, i.replacement))
            }
            if !ok, !isClean { print("    expected: \(expects[0])") }
        }
    }
}

latencies.sort()
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f%% (%d/%d)", 100 * Double(a) / Double(b), a, b) }
let p50 = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
let p95 = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
print("\n== aure-eval: \(cases.count) cases, prompt \(promptStyle.rawValue), \(arg("--ollama").map { "ollama \($0)" } ?? "server \(server)")")
print("rejected by validator: \(rejected);  latency p50 / p95: \(p50) ms / \(p95) ms")
if scores.contains(where: { $0.errTotal + $0.cleanTotal > 0 }) {
    print("| min confidence | errors fixed exactly | errors changed | clean kept |")
    print("|---|---|---|---|")
    for (k, t) in thresholds.enumerated() {
        let s = scores[k]
        print("| \(t) | \(pct(s.exact, s.errTotal)) | \(pct(s.fixedSome, s.errTotal)) | \(pct(s.cleanKept, s.cleanTotal)) |")
    }
}
if sawRewrite {
    let ratios = rw.lengthRatios.sorted()
    let median = ratios.isEmpty ? 0 : ratios[ratios.count / 2]
    print("| alternative offered (needs work) | left alone (already good) | facts kept | median length (words) |")
    print("|---|---|---|---|")
    print("| \(pct(rw.offered, rw.improveTotal)) | \(pct(rw.goodLeftAlone, rw.goodTotal)) | \(pct(rw.factsKept, rw.offeredTotal)) | \(String(format: "%.0f%%", median * 100)) |")
}

if let outPath {
    try (outLines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    print("wrote \(outLines.count) results to \(outPath)")
}
