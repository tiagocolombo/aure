import AureCore
import Darwin
import Foundation
import Security

/// A helper process (llama-server) that cannot borrow Aure's privacy permissions.
///
/// - Started with `posix_spawn` as its own TCC "responsible process", so it does
///   not inherit Aure's Accessibility permission (a child normally does).
/// - Gets a minimal environment (no DYLD_*, LLAMA_ARG_* or other variables that
///   `launchctl setenv` could inject) and no file descriptors besides 0, 1 and 2.
/// - Runs inside a sandbox profile when one is given (see `HelperSandbox`).
final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var exitCode: Int32?
    private var source: DispatchSourceProcess?

    /// `onExit` runs once on a background queue with the exit code (128 + signal when killed).
    init(executable: URL, arguments: [String], environment: [String: String], output: FileHandle?,
         sandboxProfile: String? = nil, sandboxParameters: [String: String] = [:],
         onExit: @escaping @Sendable (Int32) -> Void) throws {
        var path = executable.path
        var argv = [path] + arguments
        if let sandboxProfile {
            path = HelperSandbox.sandboxExec
            argv = [path, "-p", sandboxProfile]
                + sandboxParameters.sorted { $0.key < $1.key }.flatMap { ["-D", "\($0.key)=\($0.value)"] }
                + [executable.path] + arguments
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults)
        for sig in 1..<NSIG where sig != SIGKILL && sig != SIGSTOP { sigaddset(&defaults, sig) }
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        if !Self.disclaimResponsibility(&attr) {
            Log.info("helper: could not disclaim TCC responsibility")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let output {
            posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, 1)
            posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { (s: String) in strdup(s) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { (k, v) in strdup("\(k)=\(v)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }

        var pid: pid_t = 0
        let err = posix_spawn(&pid, path, &actions, &attr, cArgs, cEnv)
        guard err == 0 else { throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EINVAL) }
        self.pid = pid

        self.onExit = onExit
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        // The handler keeps this object alive until the child exits and is reaped.
        source.setEventHandler { self.finish() }
        self.source = source
        source.resume()
        // A child that exited before the source was registered may never fire it.
        if reap(blocking: false) != nil { DispatchQueue.global(qos: .utility).async { self.finish() } }
    }

    private let onExit: @Sendable (Int32) -> Void
    private var notified = false

    /// Reaps the child and calls `onExit`, once.
    private func finish() {
        let code = reap(blocking: true) ?? -1
        let first = lock.withLock {
            defer { notified = true; source?.cancel(); source = nil }
            return !notified
        }
        if first { onExit(code) }
    }

    var isRunning: Bool { reap(blocking: false) == nil }

    /// The exit code once the process has exited.
    var terminationStatus: Int32? { lock.withLock { exitCode } }

    func terminate() { if isRunning { kill(pid, SIGTERM) } }
    func forceKill() { if isRunning { kill(pid, SIGKILL) } }

    /// Reaps the process once; later calls return the stored exit code.
    private func reap(blocking: Bool) -> Int32? {
        lock.withLock {
            if let exitCode { return exitCode }
            var status: Int32 = 0
            guard waitpid(pid, &status, blocking ? 0 : WNOHANG) == pid else { return nil }
            let signal = status & 0x7f
            exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            return exitCode
        }
    }

    /// `responsibility_spawnattrs_setdisclaim` (libsystem, macOS 10.14+) is how
    /// Terminal-like apps keep children from using their TCC permissions. It is
    /// not in the public headers, so look it up at run time.
    private static func disclaimResponsibility(_ attr: inout posix_spawnattr_t?) -> Bool {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return false
        }
        return unsafeBitCast(sym, to: Disclaim.self)(&attr, 1) == 0
    }

    /// The environment a helper gets: nothing inherited from Aure's.
    static func minimalEnvironment() -> [String: String] {
        ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }
}

/// Sandbox for llama-server, a native parser of model files that may come from
/// anywhere (LM Studio, the Hugging Face cache, ...). Should a crafted model take
/// it over, the process can still serve on localhost and use the GPU, but cannot
/// read the user's files outside the model's folder, write anywhere but the temp
/// and cache folders, connect out, or start other programs.
enum HelperSandbox {
    static let sandboxExec = "/usr/bin/sandbox-exec"

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: sandboxExec) }

    /// Later rules win, so each deny is followed by its narrow exceptions.
    static let profile = """
    (version 1)
    (allow default)
    (deny network-outbound (remote ip))
    (deny file-read-data (subpath (param "HOME")))
    (allow file-read-data
        (subpath (param "MODEL_DIR"))
        (subpath (param "MODEL_REAL_DIR"))
        (subpath (param "HELPER_DIR")))
    (deny file-write*)
    (allow file-write*
        (subpath "/private/var/folders")
        (literal "/dev/null")
        (literal "/dev/dtracehelper"))
    (deny process-fork)
    (deny process-exec)
    (allow process-exec (literal (param "HELPER")))
    """

    /// Sandbox paths are matched after symlinks are resolved (/tmp is /private/tmp).
    static func parameters(helper: URL, model: URL) -> [String: String] {
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        return [
            "HOME": real(URL(fileURLWithPath: NSHomeDirectory())),
            "HELPER": real(helper),
            "HELPER_DIR": real(helper.deletingLastPathComponent()),
            // Hugging Face snapshots are symlinks into a blobs folder: allow both.
            "MODEL_DIR": real(model.deletingLastPathComponent()),
            "MODEL_REAL_DIR": real(model).isEmpty ? "/nonexistent" : URL(fileURLWithPath: real(model)).deletingLastPathComponent().path,
        ]
    }
}

/// Code signature checks for bundled helpers.
enum CodeSignature {
    /// True when `url` has a valid signature from the same certificate as this app
    /// (the leaf certificates are compared byte for byte). An ad-hoc signed app (a
    /// local or CI build) has no certificate to compare, so then only the helper's
    /// own signature must be valid.
    static func matchesOwnSigner(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess else { return false }
        var me: SecCode?
        var staticMe: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return false }
        guard let mine = leafCertificate(staticMe) else { return true }
        return leafCertificate(code) == mine
    }

    /// DER bytes of the certificate that signed `code`, nil when ad-hoc signed.
    static func leafCertificate(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}

/// Which local processes listen on a TCP port (libproc). Other users' processes
/// cannot be inspected, which is the point: a port nobody of ours listens on is
/// served by someone else.
public enum LocalListener {
    /// TCP ports `pid` listens on.
    public static func ports(of pid: pid_t) -> Set<Int> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var out = Set<Int>()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
            guard n == Int32(MemoryLayout<socket_fdinfo>.size), si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            out.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
        }
        return out
    }

    /// This user's processes running `executable` whose parent is launchd: helpers
    /// left behind when Aure crashed or was killed (a clean quit stops them). They
    /// keep a model in memory and serve the last text checked, so they are stopped.
    public static func orphans(of executable: URL) -> [pid_t] {
        processes(running: executable, parent: 1)
    }

    /// This user's processes running `executable` whose parent is `parent`.
    static func processes(running executable: URL, parent: pid_t) -> [pid_t] {
        let target = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return ownProcesses().filter { pid, info in
            guard info.pbi_ppid == UInt32(parent) else { return false }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().standardizedFileURL.path == target
        }.map(\.0)
    }

    static func ownProcesses() -> [(pid_t, proc_bsdinfo)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let uid = getuid()
        return pids.prefix(Int(max(got, 0))).compactMap { pid in
            var info = proc_bsdinfo()
            guard pid > 0,
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_uid == uid else { return nil }
            return (pid, info)
        }
    }

    /// True when a process of the current user listens on `port` (about 10 ms).
    public static func isOwnedByCurrentUser(port: Int) -> Bool {
        ownProcesses().contains { ports(of: $0.0).contains(port) }
    }
}
