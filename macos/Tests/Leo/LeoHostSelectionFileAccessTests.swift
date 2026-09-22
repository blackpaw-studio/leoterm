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
        let directory = LeoHostSelectionTestSupport.makeIsolatedSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stale = LeoHostSelectionTestSupport.expectedControlPath(configuration, in: directory)
        #expect(FileManager.default.createFile(atPath: stale, contents: Data()))

        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], transport: LeoAlwaysHealthyTransport(), localSocketDirectory: directory
        )
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))
        await LeoHostSelectionTestSupport.awaitConnected(
            selection, LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration, in: directory)
        )

        #expect(!FileManager.default.fileExists(atPath: stale))
        selection.shutdown()
    }
}
