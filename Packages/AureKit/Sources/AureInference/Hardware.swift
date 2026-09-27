import Darwin
import Foundation

/// What this Mac can run.
public struct Hardware: Sendable, Equatable {
    public var isAppleSilicon: Bool
    public var memoryBytes: UInt64
    public var cpuName: String
    public var performanceCores: Int
    public var hasAVX2: Bool

    public var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }

    /// Paragraphs of a long email checked at the same time. Apple Silicon GPUs
    /// batch parallel requests well; on Intel the CPU is already saturated by
    /// one request, so parallel slots give little (measured in docs/MODEL_EVAL.md).
    public var recommendedParallelSlots: Int {
        guard isAppleSilicon else { return 1 }
        return memoryGB >= 16 ? 4 : 2
    }

    public static let current: Hardware = {
        let arm = sysctlInt("hw.optional.arm64") == 1
        let mem = UInt64(sysctlInt64("hw.memsize"))
        let perf = sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 4
        return Hardware(isAppleSilicon: arm,
                        memoryBytes: mem,
                        cpuName: sysctlString("machdep.cpu.brand_string") ?? (arm ? "Apple Silicon" : "Intel"),
                        performanceCores: max(1, perf),
                        hasAVX2: arm ? false : (sysctlInt("hw.optional.avx2_0") == 1))
    }()

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func sysctlInt64(_ name: String) -> Int64 {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : 0
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
