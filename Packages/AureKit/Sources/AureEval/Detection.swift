import AureCore
import AureInference
import Foundation

// aure-eval --detect eval/detection/detection.jsonl
//
// Runs DialectDetector (Apple's language recognizer and the system spell
// checker, no model) over the detection corpus. Each JSONL line:
//   {"text": "...", "expect": "pt_BR" | "en_US" | "en_GB" | "en_CA" | "fallback",
//    "fallback": "en_US", "note": "..."}
// "fallback" means the text is too short or unclear and must keep `fallback`.

struct DetectionCase: Decodable {
    var text: String
    var expect: String
    var fallback: Dialect
    var note: String?
}

@MainActor
func runDetection(_ path: String) throws {
    let cases = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { try JSONDecoder().decode(DetectionCase.self, from: Data($0.utf8)) }

    var groups: [String: (hits: Int, total: Int)] = [:]
    var order: [String] = []
    var languageHits = 0, languageTotal = 0
    var misses: [String] = []
    _ = DialectDetector.detect("Warm up the spell checker before timing.", fallback: .enUS)
    let clock = ContinuousClock()
    var elapsed = Duration.zero

    for c in cases {
        let started = clock.now
        let r = DialectDetector.detect(c.text, fallback: c.fallback)
        elapsed += clock.now - started

        let group: String
        let ok: Bool
        if c.expect == "fallback" {
            group = "short text keeps fallback"
            ok = r.dialect == c.fallback && !r.detected
        } else {
            guard let want = Dialect(rawValue: c.expect) else { throw CocoaError(.coderInvalidValue) }
            group = c.note?.hasPrefix("neutral") == true ? "neutral English keeps preferred" : want.rawValue
            ok = r.detected && r.dialect == want
            languageTotal += 1
            if r.detected, r.dialect.language == want.language { languageHits += 1 }
        }
        if groups[group] == nil { order.append(group) }
        groups[group, default: (0, 0)].total += 1
        if ok { groups[group, default: (0, 0)].hits += 1 }
        else { misses.append("✘ want \(c.expect) (fallback \(c.fallback.rawValue)), got \(r.dialect.rawValue)\(r.detected ? "" : " [not detected]"): \(c.text)") }
    }

    let hits = groups.values.map(\.hits).reduce(0, +)
    let perCase = elapsed / max(1, cases.count)
    print("== aure-eval --detect: \(cases.count) cases from \(path)")
    print("| group | right |")
    print("|---|---|")
    for g in order { print("| \(g) | \(groups[g]!.hits)/\(groups[g]!.total) |") }
    print("| **total** | **\(hits)/\(cases.count)** |")
    print("language right: \(languageHits)/\(languageTotal);  \(perCase.formatted(.units(allowed: [.milliseconds, .microseconds], width: .narrow))) per text")
    for m in misses { print(m) }
}
