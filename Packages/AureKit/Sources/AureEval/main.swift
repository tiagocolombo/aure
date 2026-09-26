import AureCore
import AureInference
import Foundation

// aure-eval: run golden cases through the real correction pipeline.
//
//   swift run aure-eval --server http://127.0.0.1:18080 [--set eval/golden] [--limit N] [--verbose]
//
// Each JSONL line: {"text": "...", "tone": "formal", "dialect": "en_US",
//                   "expect": ["acceptable output", ...] | null (= must stay unchanged),
//                   "mode": "correct"}

struct Case: Decodable {
    var text: String
    var tone: Tone?
    var dialect: Dialect?
    var mode: CheckMode?
    var expect: [String]?
    var note: String?
}

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let server = arg("--server") ?? "http://127.0.0.1:18080"
let setPath = arg("--set") ?? "eval/golden"
let limit = Int(arg("--limit") ?? "") ?? .max
let verbose = CommandLine.arguments.contains("--verbose")

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

let provider = LlamaServerProvider(baseURL: URL(string: server)!, apiKey: ProcessInfo.processInfo.environment["AURE_API_KEY"])
let service = CorrectionService(provider: provider)

var exact = 0, fixedSome = 0, cleanKept = 0, cleanTotal = 0, errTotal = 0, falseAlarm = 0, rejected = 0
var latencies: [Int] = []

for (file, c) in cases {
    let req = CheckRequest(text: c.text, tone: c.tone ?? .formal, mode: c.mode ?? .correct, dialect: c.dialect ?? .enUS)
    let started = Date()
    var out = c.text
    var status = ""
    do {
        let r = try await service.check(req)
        out = r.corrected
        latencies.append(Int(Date().timeIntervalSince(started) * 1000))
    } catch {
        rejected += 1
        status = " [\(error.localizedDescription)]"
        latencies.append(Int(Date().timeIntervalSince(started) * 1000))
    }
    let expects = c.expect ?? [c.text]
    let isClean = c.expect == nil
    let ok = expects.map(norm).contains(norm(out))
    if isClean {
        cleanTotal += 1
        if norm(out) == norm(c.text) { cleanKept += 1 } else { falseAlarm += 1 }
    } else {
        errTotal += 1
        if ok { exact += 1 }
        if norm(out) != norm(c.text) { fixedSome += 1 }
    }
    if verbose || !ok {
        print("\(ok ? "✔" : "✘") [\(file)] \(c.text)\n    → \(out)\(status)")
        if !ok, !isClean { print("    expected: \(expects[0])") }
    }
}

latencies.sort()
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f%% (%d/%d)", 100 * Double(a) / Double(b), a, b) }
let p50 = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
let p95 = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
print("""

== aure-eval: \(cases.count) cases, server \(server)
exact fix (errors):      \(pct(exact, errTotal))
changed something:       \(pct(fixedSome, errTotal))
clean text kept:         \(pct(cleanKept, cleanTotal))
false alarms:            \(pct(falseAlarm, cleanTotal))
rejected by validator:   \(rejected)
latency p50 / p95:       \(p50) ms / \(p95) ms
""")
