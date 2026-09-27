import Foundation

/// One generated token with its log-probability and the top alternatives the
/// model considered at that position. Bytes are raw UTF-8 (tokens can split
/// multi-byte characters such as emoji).
public struct TokenLogprob: Sendable, Equatable {
    public struct Alternative: Sendable, Equatable {
        public var bytes: [UInt8]
        public var logprob: Double
        public init(bytes: [UInt8], logprob: Double) {
            self.bytes = bytes
            self.logprob = logprob
        }
    }

    public var bytes: [UInt8]
    public var logprob: Double
    public var top: [Alternative]

    public init(bytes: [UInt8], logprob: Double, top: [Alternative]) {
        self.bytes = bytes
        self.logprob = logprob
        self.top = top
    }
}

/// How sure the model was that each edit is needed.
///
/// For every changed span, find the first generated token where the output
/// stops following the original text, and look at the probability the model
/// gave to simply continuing with the original there. Confidence is
/// 1 - P(keep original). "Your going" -> "You're going" scores ~1.0 because
/// keeping "Your" had ~0 probability; dropping an article the model was
/// unsure about ("to the school" -> "to school") scores ~0.6.
public enum EditConfidence {
    /// Confidence (0...1) for each hunk of `DiffEngine.hunks(from: original, to: output)`.
    /// Returns nil when tokens cannot be aligned with `output`.
    public static func score(original: String, output: String, tokens: [TokenLogprob]) -> [(hunk: DiffEngine.Hunk, confidence: Double)]? {
        let hunks = DiffEngine.hunks(from: original, to: output)
        if hunks.isEmpty { return [] }

        let generated = tokens.flatMap(\.bytes)
        let outBytes = Array(output.utf8)
        guard let base = firstIndex(of: outBytes, in: generated) else { return nil }

        var starts: [Int] = []
        var pos = 0
        for t in tokens {
            starts.append(pos)
            pos += t.bytes.count
        }
        let origBytes = Array(original.utf8)

        var delta16 = 0
        return hunks.map { h in
            let outStart16 = h.range.lowerBound + delta16
            let outEnd16 = outStart16 + h.replacement.utf16.count
            delta16 += h.replacement.utf16.count - h.range.count

            let outStartB = base + utf8Offset(output, utf16: outStart16)
            let outEndB = base + utf8Offset(output, utf16: outEnd16)
            let origStartB = utf8Offset(original, utf16: h.range.lowerBound)
            let windowEnd = max(outEndB, outStartB + 1)

            var confidence = 1.0
            for (k, t) in tokens.enumerated() {
                let ts = starts[k], te = ts + t.bytes.count
                guard te > outStartB, ts < windowEnd, !t.bytes.isEmpty else { continue }
                let oi = max(0, origStartB + (ts - outStartB))
                let cont = oi < origBytes.count ? origBytes[oi...] : []
                if cont.starts(with: t.bytes) { continue } // still copying the original
                let keep = t.top
                    .filter { !$0.bytes.isEmpty && $0.bytes != t.bytes && cont.starts(with: $0.bytes) }
                    .reduce(0.0) { $0 + exp($1.logprob) }
                confidence = max(0, min(1, 1 - keep))
                break
            }
            return (h, confidence)
        }
    }

    /// Assigns each issue the lowest confidence of the raw model edits it overlaps.
    /// Issues that no model edit touched (e.g. from the system spell checker) get 1.
    public static func apply(_ scored: [(hunk: DiffEngine.Hunk, confidence: Double)], to issues: [Issue]) -> [Issue] {
        issues.map { issue in
            var i = issue
            let matches = scored.filter { overlaps($0.hunk.range, issue.range) }.map(\.confidence)
            i.confidence = matches.min() ?? 1
            return i
        }
    }

    static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        if a.isEmpty && b.isEmpty { return a.lowerBound == b.lowerBound }
        if a.isEmpty { return b.lowerBound <= a.lowerBound && a.lowerBound <= b.upperBound }
        if b.isEmpty { return a.lowerBound <= b.lowerBound && b.lowerBound <= a.upperBound }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    static func utf8Offset(_ s: String, utf16 offset: Int) -> Int {
        let u16 = s.utf16
        let clamped = min(max(0, offset), u16.count)
        let idx = u16.index(u16.startIndex, offsetBy: clamped)
        guard let scalarIdx = idx.samePosition(in: s.unicodeScalars) else {
            // Inside a surrogate pair: round down to the scalar start.
            return s.utf8.distance(from: s.utf8.startIndex, to: s.unicodeScalars.index(before: s.unicodeScalars.index(after: idx)))
        }
        return s.utf8.distance(from: s.utf8.startIndex, to: scalarIdx)
    }

    static func firstIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        if needle.isEmpty { return 0 }
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
        }
        return nil
    }
}
