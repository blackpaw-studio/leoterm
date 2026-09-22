import Foundation
import Testing

@testable import Ghostty

/// `LeoHostSelection` owns exactly one app-owned SSH tunnel for the
/// currently selected remote host. Uses the real `fake_ssh.py` fixture
/// (invoked directly via its shebang, so the exact argv `LeoSSHCommand`
/// builds is what actually runs). Generation-race/teardown-ordering tests
/// live in `LeoHostSelectionRaceTests`.
@Suite(.serialized)
@MainActor struct LeoHostSelectionTests {
    @Test func selectingLocalhostIsImmediatelyConnected() async {
        let selection = LeoHostSelectionTestSupport.makeSelection()
        await selection.start(flavor: .legacy)
        #expect(selection.selected == .local)
        #expect(selection.state == .connected(socketPath: LeoHostSelectionTestSupport.localSocketPath))
    }

    /// Root cause of the smoke-test failure: `${TMPDIR}` on macOS (the
    /// per-process confined `/var/folders/<random>/T/`) is long enough that
    /// `<TMPDIR>leoterm/<name>-<uuid>.sock` regularly exceeds the ~100-byte
    /// AF_UNIX path limit `LeoSSHCommand.tunnelArguments` enforces -- a
    /// realistic host name (e.g. "loopback", unlike the 4-character names
    /// used elsewhere in this suite that happened to stay just under the
    /// limit) reliably pushes it over, so `connect()` throws
    /// `invalidSocketPath` before ever launching ssh. The local socket base
    /// directory must be short and stable (`/tmp`, not `$TMPDIR`).
    @Test func selectingARealisticallyNamedHostStaysUnderTheSocketPathLimitAndConnects() async throws {
        let configuration = LeoHostConfiguration(name: "loopback", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: LeoAlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("loopback"))
        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration)
        #expect(expectedPath.utf8.count <= 100, "the local socket path itself must stay within the AF_UNIX limit")
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)

        selection.shutdown()
    }

    /// The local tunnel socket grants full control of the remote leo
    /// daemon to any local process that can connect to it -- the base
    /// directory it lives in must not be readable/writable by other local
    /// users. A fresh directory is created owner-only (`0700`).
    @Test func selectingARemoteHostCreatesTheSocketDirectoryWithOwnerOnlyPermissions() async throws {
        let directory = LeoHostSelectionTestSupport.makeIsolatedSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let configuration = LeoHostConfiguration(name: "loopback", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], transport: LeoAlwaysHealthyTransport(), localSocketDirectory: directory
        )
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("loopback"))
        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration, in: directory)
        #expect(expectedPath == directory.appendingPathComponent(configuration.localSocketFileName).path)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        selection.shutdown()
    }

    /// If the directory already exists with looser permissions (e.g. an
    /// upgrade from a version of the app that used a different mode, or
    /// tampering by another local user before this user's session created
    /// it), it's tightened rather than trusted as-is.
    @Test func selectingARemoteHostTightensAnExistingLooselyPermissionedSocketDirectory() async throws {
        let directory = LeoHostSelectionTestSupport.makeIsolatedSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        let before = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((before[.posixPermissions] as? NSNumber)?.intValue == 0o755)

        let configuration = LeoHostConfiguration(name: "loopback", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], transport: LeoAlwaysHealthyTransport(), localSocketDirectory: directory
        )
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("loopback"))
        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration, in: directory)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)

        let after = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((after[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        selection.shutdown()
    }

    @Test func selectingAConfiguredRemoteHostConnectsWithExpectedSocketPathAndArgv() async throws {
        let argvFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_ARGV_FILE", argvFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_ARGV_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: LeoAlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))
        let expectedLocalPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedLocalPath)

        let expectedArguments = try LeoSSHCommand(configuration: configuration).tunnelArguments(
            localSocketPath: expectedLocalPath,
            remoteSocketPath: "/remote/leo.sock",
            controlPath: LeoHostSelectionTestSupport.expectedControlPath(configuration)
        )
        await awaitCondition { FileManager.default.fileExists(atPath: argvFile) }
        let actualArgv = try String(contentsOfFile: argvFile, encoding: .utf8).components(separatedBy: "\n")
        #expect(actualArgv == expectedArguments)

        selection.shutdown()
    }

    @Test func tildeRemoteSocketPathIsResolvedThroughTheHomeCommand() async throws {
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "~/leo.sock")
        let runner = LeoFakeHomeRunner(stdout: "/home/evan")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: LeoAlwaysHealthyTransport(), runner: runner)
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))
        let expectedLocalPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedLocalPath)

        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.arguments == (try LeoSSHCommand(configuration: configuration).remoteHomeCommand()))

        selection.shutdown()
    }

    @Test func exitedSSHPublishesFailedWithStderrTailAndHostKeyHint() async {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", "1")
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", "Host key verification failed for work.\n")
        defer {
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", nil)
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", nil)
        }
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration])
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))
        await LeoHostSelectionTestSupport.awaitFailed(selection)

        guard case .failed(let message, let hint) = selection.state else { Issue.record("expected .failed"); return }
        #expect(message == "Host key verification failed for work.\n")
        #expect(hint == "Run `ssh evan@work` once in a terminal to accept the host key")
    }

    @Test func exitedSSHPublishesFailedWithPermissionDeniedHint() async {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", "1")
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", "Permission denied (publickey).\n")
        defer {
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", nil)
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", nil)
        }
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration])
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))
        await LeoHostSelectionTestSupport.awaitFailed(selection)

        guard case .failed(_, let hint) = selection.state else { Issue.record("expected .failed"); return }
        #expect(hint == "ssh needs a key or agent in BatchMode; try `ssh evan@work` in a terminal")
    }
}
