import Darwin
import Foundation
import Testing
@testable import AureInference

@Suite struct HelperProcessTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aure-helper-\(UUID().uuidString)")

    /// Runs `executable` to completion and returns its exit code and output.
    func run(_ executable: String, _ arguments: [String], sandboxed: Bool = false,
             model: URL = URL(fileURLWithPath: "/nonexistent/m.gguf")) async throws -> (Int32, String) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("out-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        let exe = URL(fileURLWithPath: executable)
        let code: Int32 = try await withCheckedThrowingContinuation { cont in
            do {
                _ = try ChildProcess(executable: exe, arguments: arguments, environment: ChildProcess.minimalEnvironment(),
                                     output: handle, sandboxProfile: sandboxed ? HelperSandbox.profile : nil,
                                     sandboxParameters: HelperSandbox.parameters(helper: exe, model: model)) { cont.resume(returning: $0) }
            } catch { cont.resume(throwing: error) }
        }
        try handle.close()
        return (code, try String(contentsOf: out, encoding: .utf8))
    }

    @Test func helpersGetAMinimalEnvironment() async throws {
        setenv("LLAMA_ARG_HOST", "0.0.0.0", 1)
        defer { unsetenv("LLAMA_ARG_HOST") }
        let (code, output) = try await run("/usr/bin/env", [])
        #expect(code == 0)
        #expect(Set(output.split(separator: "\n").map { String($0.split(separator: "=")[0]) }) == ["HOME", "TMPDIR", "PATH"])
    }

    @Test func reportsExitCodes() async throws {
        #expect(try await run("/bin/sh", ["-c", "exit 3"]).0 == 3)
    }

    @Test func helpersDoNotInheritOpenFiles() async throws {
        // Opened without close-on-exec, at a number the child would not reuse.
        let opened = open("/dev/zero", O_RDONLY)
        let fd = dup2(opened, 217)
        close(opened)
        defer { close(fd) }
        #expect(fd == 217)
        let (_, output) = try await run("/bin/sh", ["-c", "ls /dev/fd"])
        #expect(!output.split(separator: "\n").contains(Substring(String(fd))))
    }

    @Test func sandboxKeepsHelpersOutOfTheHomeFolder() async throws {
        guard HelperSandbox.isAvailable else { return }
        let secret = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".aure-test-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        #expect(try await run("/bin/cat", [secret.path], sandboxed: true).0 != 0)
        #expect(try await run("/bin/cat", [secret.path], sandboxed: false).1 == "secret")
    }

    @Test func sandboxAllowsTheModelFolder() async throws {
        guard HelperSandbox.isAvailable else { return }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".aure-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: modelDir) }
        let model = modelDir.appendingPathComponent("m.gguf")
        try Data("GGUF".utf8).write(to: model)
        #expect(try await run("/bin/cat", [model.path], sandboxed: true, model: model).1 == "GGUF")
    }

    @Test func keyFileIsPrivate() throws {
        let url = try LlamaServerProcess.writeKeyFile("k")
        defer { try? FileManager.default.removeItem(at: url) }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "k\n")
    }

    @Test func findsOwnListeningPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        #expect(listen(fd, 1) == 0)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        #expect(LocalListener.ports(of: getpid()).contains(port))
        #expect(LocalListener.isOwnedByCurrentUser(port: port))
    }

    @Test func findsHelpersLeftRunningByAnEarlierParent() async throws {
        // A private copy, so only this test's process matches. The shell exits at
        // once, so launchd adopts its background sleep: an orphan.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sleeper = dir.appendingPathComponent("sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleeper)
        // A copied system binary only runs once re-signed.
        #expect(try await run("/usr/bin/codesign", ["-f", "-s", "-", sleeper.path]).0 == 0)
        _ = try await run("/bin/sh", ["-c", "'\(sleeper.path)' 30 & exit 0"])
        // The background child may still be a forked shell until its exec completes
        // (slow on CI runners), so wait for it to show up.
        var orphans: [pid_t] = []
        for _ in 0..<100 where orphans.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            orphans = LocalListener.orphans(of: sleeper)
        }
        defer { orphans.forEach { kill($0, SIGTERM) } }
        #expect(!orphans.isEmpty)
        #expect(!orphans.contains(getpid()))
    }
}
