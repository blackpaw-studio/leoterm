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

    /// The most a create may pull from its source in one read.
    var writeChunkSize: Int {
        switch self {
        case .local: LeoLocalFileBackend.writeChunkSize
        case .sftpSmallChunks: 1000
        case .sftp, .sftpWithoutPosixRename, .sshEndToEnd: LeoSFTPOptions().chunkSize
        }
    }

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

/// Uses one launcher for the first child and another for every later child.
/// This makes the handoff from a stale successful handshake deterministic.
final class LeoSequenceSFTPLauncher: LeoSFTPLaunching, @unchecked Sendable {
    private let first: any LeoSFTPLaunching
    private let later: any LeoSFTPLaunching
    private let lock = NSLock()
    private var count = 0

    var launches: Int { lock.withLock { count } }

    init(first: any LeoSFTPLaunching, later: any LeoSFTPLaunching) {
        self.first = first
        self.later = later
    }

    func launch() throws -> LeoSFTPChannel {
        let index = lock.withLock {
            defer { count += 1 }
            return count
        }
        return try (index == 0 ? first : later).launch()
    }
}

/// A guard for regressions that would otherwise launch children forever.
final class LeoLimitedSFTPLauncher: LeoSFTPLaunching, @unchecked Sendable {
    private let base: any LeoSFTPLaunching
    private let limit: Int
    private let lock = NSLock()
    private var count = 0

    var attempts: Int { lock.withLock { count } }

    init(_ base: any LeoSFTPLaunching, limit: Int) {
        self.base = base
        self.limit = limit
    }

    func launch() throws -> LeoSFTPChannel {
        let attempt = lock.withLock {
            count += 1
            return count
        }
        guard attempt <= limit else {
            throw LeoFileAccessError.unavailable(reason: "test launch limit reached")
        }
        return try base.launch()
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

/// A `Data` source that records every read's requested size.
final class LeoRecordingByteSource: LeoFileByteSource, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var requests: [Int] = []

    init(_ data: Data) {
        self.data = data
    }

    var requestedCounts: [Int] { lock.withLock { requests } }

    func read(at offset: UInt64, upTo count: Int) throws -> Data {
        lock.withLock { requests.append(count) }
        return try data.read(at: offset, upTo: count)
    }
}

/// The real `/usr/libexec/sftp-server` behind a frame relay that loses the
/// first RENAME (type 18) at a chosen point, then cuts the client off as a
/// dropped ControlMaster would. Frame-driven, so no timing is involved.
final class LeoSFTPRenameLossRelay: LeoSFTPLaunching, @unchecked Sendable {
    enum Loss {
        /// The server performs the RENAME; its reply never arrives.
        case reply
        /// The connection drops before the server sees the RENAME.
        case request
    }

    private static let renameType: UInt8 = 18
    private static let removeType: UInt8 = 13

    private let loss: Loss
    private let base = LeoSFTPTestServer.launcher()
    private let lock = NSLock()
    private var launchCount = 0
    private var renameCount = 0
    private var removesAfterRenameCount = 0
    private var lostReplyID: UInt32?

    init(losing loss: Loss) {
        self.loss = loss
    }

    var launches: Int { lock.withLock { launchCount } }
    var renames: Int { lock.withLock { renameCount } }
    var removesAfterRename: Int { lock.withLock { removesAfterRenameCount } }

    func launch() throws -> LeoSFTPChannel {
        lock.withLock { launchCount += 1 }
        let server = try base.launch()
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
            server.terminate()
            throw LeoFileAccessError.unavailable(reason: "socketpair failed")
        }
        let (client, relay) = (ends[0], ends[1])
        _ = fcntl(relay, F_SETNOSIGPIPE, 1)
        let group = DispatchGroup()
        Self.spawn(group) { [self] in relayRequests(from: relay, to: server.toServer.fileDescriptor) }
        Self.spawn(group) { [self] in relayReplies(from: server.fromServer.fileDescriptor, to: relay) }
        group.notify(queue: .global()) { Darwin.close(relay) }
        return LeoSFTPChannel(
            fromServer: FileHandle(fileDescriptor: client, closeOnDealloc: true),
            toServer: FileHandle(fileDescriptor: dup(client), closeOnDealloc: true),
            stop: {
                shutdown(relay, SHUT_RDWR)
                server.terminate()
            }
        )
    }

    private func relayRequests(from relay: Int32, to server: Int32) {
        while let frame = Self.readFrame(relay) {
            let type = frame[4]
            if type == Self.renameType {
                lock.withLock { renameCount += 1 }
                if loss == .request {
                    shutdown(relay, SHUT_RDWR)
                    return
                }
                lock.withLock { lostReplyID = Self.requestID(frame) }
            } else if type == Self.removeType {
                lock.withLock { if renameCount > 0 { removesAfterRenameCount += 1 } }
            }
            guard Self.writeAll(frame, to: server) else { return }
        }
    }

    private func relayReplies(from server: Int32, to relay: Int32) {
        while let frame = Self.readFrame(server) {
            // VERSION (type 2) carries no request id.
            if frame[4] != 2, let lost = lock.withLock({ lostReplyID }), Self.requestID(frame) == lost {
                shutdown(relay, SHUT_RDWR)
                return
            }
            guard Self.writeAll(frame, to: relay) else { return }
        }
        shutdown(relay, SHUT_RDWR)
    }

    private static func spawn(_ group: DispatchGroup, _ body: @escaping @Sendable () -> Void) {
        group.enter()
        Thread {
            body()
            group.leave()
        }.start()
    }

    /// One whole frame (length prefix included), or nil at EOF.
    private static func readFrame(_ descriptor: Int32) -> [UInt8]? {
        guard let header = readExactly(4, from: descriptor) else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, let body = readExactly(length, from: descriptor) else { return nil }
        return header + body
    }

    private static func requestID(_ frame: [UInt8]) -> UInt32 {
        frame[5..<9].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let read = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, count - offset) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { return nil }
            offset += read
        }
        return bytes
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}
