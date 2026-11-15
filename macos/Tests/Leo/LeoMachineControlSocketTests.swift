import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A machine's SFTP file access multiplexes over its tunnel's own
/// ControlMaster socket, so what sits at that path decides whether files
/// open. Real tunnels over `fake_ssh.py`.
@Suite(.serialized)
@MainActor struct LeoMachineControlSocketTests {
    private typealias Support = LeoMachineTunnelTestSupport

    private let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
    private var host: LeoHostID { .remote(configuration.name) }

    /// A master killed without cleanup (crash, SIGKILL) leaves its socket
    /// behind; ssh's ControlMaster=yes would then silently run without
    /// multiplexing, and every SFTP session would fail.
    @Test func connectingRemovesAStaleControlSocketFirst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = Support.expectedControlPath(configuration, in: directory)
        try LeoTestUnixSocket.leaveStale(stale)

        let registry = try await connect(in: directory)

        #expect(LeoControlSocket.inspect(stale) == .absent)
        registry.shutdown()
    }

    /// Someone is still listening: not ours to remove.
    @Test func connectingNeverRemovesALiveControlSocket() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = Support.expectedControlPath(configuration, in: directory)
        let descriptor = try LeoTestUnixSocket.bind(live, listening: true)
        defer { close(descriptor) }

        let registry = try await connect(in: directory)

        #expect(LeoControlSocket.inspect(live) == .live)
        #expect(try registry.makeFileAccess(for: host) is LeoFileAccessor<LeoSFTPFileBackend>)
        registry.shutdown()
    }

    /// The debug and production apps share the socket directory; each
    /// instance's master lives at its own path.
    @Test func eachAppInstanceOwnsItsOwnControlPath() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let production = Support.makeRegistry(hosts: [configuration], localSocketDirectory: directory, controlSocketInstance: "aaaaaaaa")
        let debug = Support.makeRegistry(hosts: [configuration], localSocketDirectory: directory, controlSocketInstance: "bbbbbbbb")

        let productionPath = production.environment.controlPath(for: configuration)
        #expect(productionPath != debug.environment.controlPath(for: configuration))
        #expect(productionPath.hasSuffix(configuration.controlSocketFileName(instance: "aaaaaaaa")))
    }

    /// A non-socket squatting on the control path is never removed; the
    /// tunnel runs without a master and file access says why it can't work.
    @Test(arguments: ["file", "directory", "symlink"])
    func aNonSocketAtTheControlPathIsKeptAndTheTunnelDoesNotMultiplex(_ kind: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controlPath = Support.expectedControlPath(configuration, in: directory)
        switch kind {
        case "file": #expect(FileManager.default.createFile(atPath: controlPath, contents: Data("keep".utf8)))
        case "directory": try FileManager.default.createDirectory(atPath: controlPath, withIntermediateDirectories: false)
        default: try FileManager.default.createSymbolicLink(atPath: controlPath, withDestinationPath: "/nonexistent")
        }
        let argvFile = directory.appendingPathComponent("argv").path

        let registry = try await connect(in: directory, recordingArgvTo: argvFile)

        let argv = try await Support.recordedArgv(argvFile)
        #expect(argv.contains("ControlPath=none"))
        #expect(!argv.contains("ControlMaster=yes"))
        #expect((try? FileManager.default.attributesOfItem(atPath: controlPath)) != nil, "\(kind) was removed")
        #expect(throws: LeoFileAccessError.unavailable(reason: "control path is occupied")) { try registry.makeFileAccess(for: host) }
        registry.shutdown()
    }

    /// A socket another user planted at the control path could be a fake
    /// master that sees every file: never removed, never multiplexed over.
    @Test func aForeignControlSocketIsKeptAndNeverUsed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controlPath = Support.expectedControlPath(configuration, in: directory)
        try LeoTestUnixSocket.leaveStale(controlPath)
        let argvFile = directory.appendingPathComponent("argv").path

        let registry = try await connect(in: directory, recordingArgvTo: argvFile, controlSocketOwner: geteuid() + 1)

        let argv = try await Support.recordedArgv(argvFile)
        #expect(argv.contains("ControlPath=none"))
        #expect(!argv.contains("ControlMaster=yes"))
        #expect(LeoControlSocket.inspect(controlPath) == .stale, "the foreign socket was removed")
        let expected = LeoFileAccessError.unavailable(reason: "the control socket belongs to another user")
        #expect(throws: expected) { try registry.makeFileAccess(for: host) }
        registry.shutdown()
    }

    /// A socket directory with a space makes the control path one ssh can't
    /// parse; that used to fail the whole tunnel. The forwarded socket has
    /// no such restriction.
    @Test func aSocketDirectoryWithASpaceStillConnectsWithoutFileAccess() async throws {
        let base = URL(fileURLWithPath: "/tmp/leo home \(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("leo", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let argvFile = base.appendingPathComponent("argv").path

        let registry = try await connect(in: directory, recordingArgvTo: argvFile, scriptDirectory: base)

        let argv = try await Support.recordedArgv(argvFile)
        #expect(argv.contains("ControlPath=none"))
        #expect(!argv.contains { $0.hasPrefix("ControlPath=/") })
        let expected = LeoFileAccessError.unavailable(reason: "control path unsupported")
        #expect(throws: expected) { try registry.makeFileAccess(for: host) }
        #expect(expected.localizedDescription.localizedCaseInsensitiveContains("file access unavailable: control path unsupported"))
        registry.shutdown()
    }

    /// A socket directory that isn't provably ours (here a planted
    /// symlink) is never used: the forwarded daemon socket lives there
    /// too, so the tunnel doesn't start, and says why.
    @Test func anUnsafeControlDirectoryFailsTheTunnel() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controlDirectory = directory.appendingPathComponent("cm", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: controlDirectory, withDestinationURL: directory)
        let registry = Support.makeRegistry(
            hosts: [configuration], localSocketDirectory: directory, controlSocketDirectory: controlDirectory
        )

        registry.start(flavor: .socketEvents)

        await Support.awaitFailed(registry, host)
        #expect(registry.connectionState(for: host) == .failed(message: "The tunnel socket directory is not private", hint: nil))
        registry.shutdown()
    }

    private func makeDirectory() throws -> URL {
        let directory = Support.makeIsolatedSocketDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Connects `configuration` with sockets in `directory` and waits for
    /// `.connected`, optionally through an argv-recording fake ssh.
    private func connect(
        in directory: URL,
        recordingArgvTo argvFile: String? = nil,
        scriptDirectory: URL? = nil,
        controlSocketOwner: uid_t = geteuid()
    ) async throws -> LeoMachineRegistry {
        let ssh = try argvFile.map {
            try Support.argvRecordingSSH(in: scriptDirectory ?? directory, argvFile: $0)
        } ?? LeoTunnelTestSupport.fixtureURL()
        let registry = Support.makeRegistry(
            hosts: [configuration], localSocketDirectory: directory, sshExecutable: ssh, controlSocketOwner: controlSocketOwner
        )
        registry.start(flavor: .socketEvents)
        await Support.awaitConnected(registry, host, Support.expectedLocalSocketPath(configuration, in: directory))
        return registry
    }
}
