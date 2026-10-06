import Foundation
import Testing

@testable import Ghostty

/// Every backend the shared contract suite runs against. A contract test
/// takes one of these as its argument, so each behaviour is asserted
/// identically for local and remote.
enum LeoFileBackendKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    static var allCases: [LeoFileBackendKind] {
        [.local, .sftp, .sftpSmallChunks, .sftpWithoutPosixRename] + (LeoSSHEndToEnd.isEnabled ? [.sshEndToEnd] : [])
    }

    case local
    /// macOS's own `/usr/libexec/sftp-server` over pipes -- no ssh, no sshd.
    case sftp
    /// Tiny chunks and a narrow window, so every operation spans many
    /// pipelined round trips.
    case sftpSmallChunks
    /// Ignores `posix-rename@openssh.com`, exercising REMOVE + RENAME.
    case sftpWithoutPosixRename
    /// Real `ssh` to `LEO_SSH_E2E_HOST`, over the suite's ControlMaster
    /// (`LeoSSHEndToEnd`). Only listed when that variable is set.
    case sshEndToEnd

    var testDescription: String { rawValue }

    func makeAccess() -> any LeoFileAccess {
        switch self {
        case .local: LeoFileAccessor.local()
        case .sftp: LeoFileAccessor.sftp(launcher: LeoSFTPTestServer.launcher())
        case .sftpSmallChunks:
            LeoFileAccessor.sftp(launcher: LeoSFTPTestServer.launcher(), options: .init(chunkSize: 1000, maxRequestsInFlight: 3))
        case .sftpWithoutPosixRename:
            LeoFileAccessor.sftp(launcher: LeoSFTPTestServer.launcher(), options: .init(usesPosixRename: false))
        case .sshEndToEnd:
            // Reached only through `withLeoFileSandbox`, which uses the
            // suite's master instead; a launcher that can't start keeps any
            // other caller failing loudly.
            LeoFileAccessor.sftp(launcher: LeoSFTPProcessLauncher(executable: URL(fileURLWithPath: "/nonexistent/ssh"), arguments: []))
        }
    }
}

enum LeoSFTPTestServer {
    static let executable = URL(fileURLWithPath: "/usr/libexec/sftp-server")

    /// `-d %d` starts in the user's home, as sshd does for a real session
    /// (run directly, sftp-server would stay in the test's working directory).
    static func launcher() -> LeoSFTPProcessLauncher {
        LeoSFTPProcessLauncher(executable: executable, arguments: ["-d", "%d"])
    }

    /// A fake server: `/bin/sh -c script`, speaking whatever bytes the
    /// script prints. `versionReply` is a valid v3 `SSH_FXP_VERSION` frame.
    static func script(_ script: String) -> LeoSFTPProcessLauncher {
        LeoSFTPProcessLauncher(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }

    static let versionReply = #"printf '\000\000\000\005\002\000\000\000\003'"#
}

/// Counts launches, delegating to `base`.
final class LeoCountingSFTPLauncher: LeoSFTPLaunching, @unchecked Sendable {
    private let base: any LeoSFTPLaunching
    private let lock = NSLock()
    private var count = 0

    init(_ base: any LeoSFTPLaunching) {
        self.base = base
    }

    var launches: Int { lock.withLock { count } }

    func launch() throws -> LeoSFTPChannel {
        lock.withLock { count += 1 }
        return try base.launch()
    }

    func launchFallback(after channel: LeoSFTPChannel) throws -> LeoSFTPChannel? {
        guard let fallback = try base.launchFallback(after: channel) else { return nil }
        lock.withLock { count += 1 }
        return fallback
    }
}

/// A throwaway directory for one test. `cleanUp()` restores permissions a
/// test may have removed before deleting it.
struct LeoFileSandbox {
    let root: String

    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        let base = parent.appendingPathComponent("leo-files-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.path
    }

    func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    @discardableResult
    func file(_ relative: String, _ contents: String, permissions: Int = 0o644) throws -> String {
        let full = path(relative)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: full))
        try chmod(relative, permissions)
        return full
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: destination)
        return full
    }

    func chmod(_ relative: String, _ permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path(relative))
    }

    func contents(_ relative: String) throws -> String {
        try String(contentsOfFile: path(relative), encoding: .utf8)
    }

    func permissions(_ relative: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path(relative))[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func inode(_ relative: String) throws -> UInt64 {
        try (FileManager.default.attributesOfItem(atPath: path(relative))[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func names(in relative: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: relative.isEmpty ? root : path(relative)).sorted()
    }

    func cleanUp() {
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(relative))
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Runs `body` against a fresh sandbox and a fresh accessor of `kind`,
/// always cleaning both up. `.sshEndToEnd` sandboxes live in the suite
/// master's remote temp directory.
func withLeoFileSandbox(
    _ kind: LeoFileBackendKind,
    _ body: (LeoFileSandbox, any LeoFileAccess) async throws -> Void
) async throws {
    guard kind == .sshEndToEnd else {
        return try await withLeoFileSandbox(try LeoFileSandbox(), kind.makeAccess(), body)
    }
    let connection = try #require(LeoSSHEndToEnd.current, "the suite needs LeoSSHEndToEnd.trait")
    try await connection.withSession {
        try await withLeoFileSandbox(try LeoFileSandbox(in: URL(fileURLWithPath: connection.remoteDirectory)), try connection.makeAccess(), body)
    }
}

private func withLeoFileSandbox(
    _ sandbox: LeoFileSandbox,
    _ access: any LeoFileAccess,
    _ body: (LeoFileSandbox, any LeoFileAccess) async throws -> Void
) async throws {
    defer { sandbox.cleanUp() }
    do {
        try await body(sandbox, access)
    } catch {
        await access.close()
        throw error
    }
    await access.close()
}

/// Deterministic pseudo-random bytes (a large file must not compress into
/// something a chunking bug could still reproduce by accident).
func leoPatternData(count: Int) -> Data {
    var state: UInt32 = 0x2545_F491
    return Data((0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return UInt8(truncatingIfNeeded: state)
    })
}
