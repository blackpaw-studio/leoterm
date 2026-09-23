import Foundation
import Testing

@testable import Ghostty

/// `LeoHostSelection` hands out file access for the selected host: local
/// for localhost, SFTP over the tunnel's own ControlMaster for a remote.
@Suite(.serialized)
@MainActor struct LeoHostSelectionFileAccessTests {
    private let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")

    @Test func localhostUsesTheLocalFilesystem() async throws {
        let selection = LeoHostSelectionTestSupport.makeSelection()
        await selection.start(flavor: .legacy)

        #expect(try selection.makeFileAccess() is LeoFileAccessor<LeoLocalFileBackend>)
    }

    @Test func aRemoteHostMultiplexesSFTPOverTheTunnelsControlPath() async throws {
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: LeoAlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let access = try #require(try selection.makeFileAccess() as? LeoFileAccessor<LeoSFTPFileBackend>)
        let launcher = try #require(access.backend.session.launcher as? LeoSFTPProcessLauncher)

        #expect(launcher.executable == LeoTunnelTestSupport.fixtureURL())
        #expect(launcher.arguments == (try LeoSSHCommand(configuration: configuration).sftpArguments(
            controlPath: LeoHostSelectionTestSupport.expectedControlPath(configuration)
        )))
        selection.shutdown()
    }

    @Test func anUnknownSelectedHostHasNoFileAccess() async throws {
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [], transport: LeoAlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("gone"))

        #expect(throws: LeoFileAccessError.disconnected) { try selection.makeFileAccess() }
        selection.shutdown()
    }

    /// A master killed without cleanup (crash, SIGKILL) leaves its socket
    /// behind; ssh's ControlMaster=yes would then silently run without
    /// multiplexing, and every SFTP session would fail.
    @Test func connectingRemovesAStaleControlSocketFirst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = LeoHostSelectionTestSupport.expectedControlPath(configuration, in: directory)
        try LeoTestUnixSocket.leaveStale(stale)

        let selection = try await connect(in: directory)

        #expect(LeoControlSocket.inspect(stale) == .absent)
        selection.shutdown()
    }

    /// Someone is still listening: not ours to remove.
    @Test func connectingNeverRemovesALiveControlSocket() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = LeoHostSelectionTestSupport.expectedControlPath(configuration, in: directory)
        let descriptor = try LeoTestUnixSocket.bind(live, listening: true)
        defer { close(descriptor) }

        let selection = try await connect(in: directory)

        #expect(LeoControlSocket.inspect(live) == .live)
        selection.shutdown()
    }

    /// The debug and production apps share the socket directory; each
    /// instance's master lives at its own path.
    @Test func eachAppInstanceOwnsItsOwnControlPath() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let production = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], localSocketDirectory: directory, controlSocketInstance: "aaaaaaaa"
        )
        let debug = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], localSocketDirectory: directory, controlSocketInstance: "bbbbbbbb"
        )

        #expect(production.controlPath(for: configuration) != debug.controlPath(for: configuration))
        #expect(production.controlPath(for: configuration).hasSuffix(configuration.controlSocketFileName(instance: "aaaaaaaa")))
    }

    /// A non-socket squatting on the control path is never removed; the
    /// tunnel runs without a master and file access says why it can't work.
    @Test(arguments: ["file", "directory", "symlink"])
    func aNonSocketAtTheControlPathIsKeptAndTheTunnelDoesNotMultiplex(_ kind: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controlPath = LeoHostSelectionTestSupport.expectedControlPath(configuration, in: directory)
        switch kind {
        case "file": #expect(FileManager.default.createFile(atPath: controlPath, contents: Data("keep".utf8)))
        case "directory": try FileManager.default.createDirectory(atPath: controlPath, withIntermediateDirectories: false)
        default: try FileManager.default.createSymbolicLink(atPath: controlPath, withDestinationPath: "/nonexistent")
        }
        let argvFile = directory.appendingPathComponent("argv").path

        let selection = try await connect(in: directory, recordingArgvTo: argvFile)

        let argv = try await LeoHostSelectionTestSupport.recordedArgv(argvFile)
        #expect(argv.contains("ControlPath=none"))
        #expect(!argv.contains("ControlMaster=yes"))
        #expect((try? FileManager.default.attributesOfItem(atPath: controlPath)) != nil, "\(kind) was removed")
        #expect(throws: LeoFileAccessError.unavailable(reason: "control path is occupied")) { try selection.makeFileAccess() }
        selection.shutdown()
    }

    /// A home directory with a space makes the control path one ssh can't
    /// parse; that used to fail the whole tunnel.
    @Test func aHomeDirectoryWithASpaceStillConnectsWithoutFileAccess() async throws {
        let base = URL(fileURLWithPath: "/tmp/leo home \(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent(".leo/state/leoterm", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let argvFile = base.appendingPathComponent("argv").path

        let selection = try await connect(in: directory, recordingArgvTo: argvFile, scriptDirectory: base)

        let argv = try await LeoHostSelectionTestSupport.recordedArgv(argvFile)
        #expect(argv.contains("ControlPath=none"))
        #expect(!argv.contains { $0.hasPrefix("ControlPath=/") })
        let expected = LeoFileAccessError.unavailable(reason: "control path unsupported")
        #expect(throws: expected) { try selection.makeFileAccess() }
        #expect(expected.localizedDescription.localizedCaseInsensitiveContains("file access unavailable: control path unsupported"))
        selection.shutdown()
    }

    /// A control directory that isn't provably ours (here a planted
    /// symlink) is never used: no master, and file access says why.
    @Test func anUnsafeControlDirectoryRunsTheTunnelWithoutFileAccess() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controlDirectory = directory.appendingPathComponent("cm", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: controlDirectory, withDestinationURL: directory)
        let argvFile = directory.appendingPathComponent("argv").path

        let selection = try await connect(in: directory, recordingArgvTo: argvFile, controlSocketDirectory: controlDirectory)

        let argv = try await LeoHostSelectionTestSupport.recordedArgv(argvFile)
        #expect(argv.contains("ControlPath=none"))
        #expect(!argv.contains("ControlMaster=yes"))
        #expect(throws: LeoFileAccessError.unavailable(reason: "control directory is not private")) { try selection.makeFileAccess() }
        selection.shutdown()
    }

    private func makeDirectory() throws -> URL {
        let directory = LeoHostSelectionTestSupport.makeIsolatedSocketDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Selects `configuration` with sockets in `directory` and waits for
    /// `.connected`, optionally through an argv-recording fake ssh.
    private func connect(
        in directory: URL,
        recordingArgvTo argvFile: String? = nil,
        scriptDirectory: URL? = nil,
        controlSocketDirectory: URL? = nil
    ) async throws -> LeoHostSelection {
        let ssh = try argvFile.map {
            try LeoHostSelectionTestSupport.argvRecordingSSH(in: scriptDirectory ?? directory, argvFile: $0)
        } ?? LeoTunnelTestSupport.fixtureURL()
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], transport: LeoAlwaysHealthyTransport(), localSocketDirectory: directory, sshExecutable: ssh,
            controlSocketDirectory: controlSocketDirectory
        )
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))
        await LeoHostSelectionTestSupport.awaitConnected(
            selection, LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration, in: directory)
        )
        return selection
    }
}
