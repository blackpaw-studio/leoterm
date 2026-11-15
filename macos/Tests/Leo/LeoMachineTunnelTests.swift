import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Each remote machine gets its own app-owned SSH tunnel. Uses the real
/// `fake_ssh.py` fixture (invoked directly via its shebang, so the exact
/// argv `LeoSSHCommand` builds is what actually runs). Generation races and
/// teardown ordering live in `LeoMachineRegistryTests`.
@Suite(.serialized)
@MainActor struct LeoMachineTunnelTests {
    private typealias Support = LeoMachineTunnelTestSupport

    /// `leo.selectedHost` is gone: the launch migration folds it into the
    /// last spawn machine, and nothing that connects reads or writes it.
    @Test func theOldSelectedHostKeyIsNeitherReadNorWritten() async {
        let defaults = LeoInMemoryDefaults()
        let configuration = LeoHostConfiguration(name: "other", sshTarget: "evan@other", remoteSocketPath: "/remote/leo.sock")
        let registry = Support.makeRegistry(hosts: [configuration], defaults: defaults)

        registry.start(flavor: .socketEvents)
        await Support.awaitConnected(registry, .remote("other"), Support.expectedLocalSocketPath(configuration))
        registry.reconnect(.remote("other"))
        registry.reconnect(.local)

        #expect(defaults.object(forKey: "leo.selectedHost") == nil)
        registry.shutdown()
    }

    /// Root cause of the smoke-test failure: `${TMPDIR}` on macOS (the
    /// per-process confined `/var/folders/<random>/T/`) is long enough that
    /// `<TMPDIR>leoterm/<name>-<uuid>.sock` regularly exceeds the ~100-byte
    /// AF_UNIX path limit `LeoSSHCommand.tunnelArguments` enforces -- a
    /// realistic machine name (e.g. "loopback") reliably pushes it over, so
    /// connecting throws `invalidSocketPath` before ever launching ssh. The
    /// local socket base directory must be short and stable (`/tmp`, not
    /// `$TMPDIR`).
    @Test func aRealisticallyNamedMachineStaysUnderTheSocketPathLimitAndConnects() async throws {
        let configuration = LeoHostConfiguration(name: "loopback", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let registry = Support.makeRegistry(hosts: [configuration])

        registry.start(flavor: .socketEvents)

        let expectedPath = Support.expectedLocalSocketPath(configuration)
        #expect(expectedPath.utf8.count <= 100, "the local socket path itself must stay within the AF_UNIX limit")
        await Support.awaitConnected(registry, .remote("loopback"), expectedPath)
        registry.shutdown()
    }

    /// The local tunnel socket grants full control of the remote leo
    /// daemon to any local process that can connect to it -- the base
    /// directory it lives in must not be readable/writable by other local
    /// users. A fresh directory is created owner-only (`0700`).
    @Test func connectingCreatesTheSocketDirectoryWithOwnerOnlyPermissions() async throws {
        let directory = Support.makeIsolatedSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let configuration = LeoHostConfiguration(name: "loopback", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let registry = Support.makeRegistry(hosts: [configuration], localSocketDirectory: directory)

        registry.start(flavor: .socketEvents)

        let expectedPath = Support.expectedLocalSocketPath(configuration, in: directory)
        #expect(expectedPath == registry.environment.tunnelSocketPath(for: configuration))
        await Support.awaitConnected(registry, .remote("loopback"), expectedPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        registry.shutdown()
    }

    /// If the directory already exists with looser permissions (e.g. an
    /// upgrade from a version of the app that used a different mode, or
    /// tampering by another local user before this user's session created
    /// it), it's tightened rather than trusted as-is.
    @Test func connectingTightensAnExistingLooselyPermissionedSocketDirectory() async throws {
        let directory = Support.makeIsolatedSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let configuration = LeoHostConfiguration(name: "loopback", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let registry = Support.makeRegistry(hosts: [configuration], localSocketDirectory: directory)

        registry.start(flavor: .socketEvents)

        await Support.awaitConnected(registry, .remote("loopback"), Support.expectedLocalSocketPath(configuration, in: directory))
        let after = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((after[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        registry.shutdown()
    }

    @Test func aConfiguredMachineConnectsWithTheExpectedSocketPathAndArgv() async throws {
        let directory = Support.makeIsolatedSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let argvFile = directory.appendingPathComponent("argv").path
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let registry = Support.makeRegistry(
            hosts: [configuration], localSocketDirectory: directory,
            sshExecutable: try Support.argvRecordingSSH(in: directory, argvFile: argvFile)
        )

        registry.start(flavor: .socketEvents)

        let expectedLocalPath = Support.expectedLocalSocketPath(configuration, in: directory)
        await Support.awaitConnected(registry, .remote("work"), expectedLocalPath)
        let expectedArguments = try LeoSSHCommand(configuration: configuration).tunnelArguments(
            localSocketPath: expectedLocalPath,
            remoteSocketPath: "/remote/leo.sock",
            controlPath: Support.expectedControlPath(configuration, in: directory)
        )
        #expect(try await Support.recordedArgv(argvFile) == expectedArguments)
        registry.shutdown()
    }

    @Test func aTildeRemoteSocketPathIsResolvedThroughTheHomeCommand() async throws {
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "~/leo.sock")
        let runner = LeoFakeHomeRunner(stdout: "/home/evan")
        let registry = Support.makeRegistry(hosts: [configuration], runner: runner)

        registry.start(flavor: .socketEvents)

        await Support.awaitConnected(registry, .remote("work"), Support.expectedLocalSocketPath(configuration))
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.arguments == (try LeoSSHCommand(configuration: configuration).remoteHomeCommand()))
        registry.shutdown()
    }

    @Test(arguments: [
        ("Host key verification failed for work.\n", "Run `ssh evan@work` once in a terminal to accept the host key"),
        ("Permission denied (publickey).\n", "ssh needs a key or agent in BatchMode; try `ssh evan@work` in a terminal"),
    ])
    func anExitedSSHFailsTheMachineWithItsStderrTailAndAHint(_ stderr: String, _ hint: String) async {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", "1")
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", stderr)
        defer {
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", nil)
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", nil)
        }
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let registry = Support.makeRegistry(hosts: [configuration])

        registry.start(flavor: .socketEvents)

        await Support.awaitFailed(registry, .remote("work"))
        #expect(Support.failure(registry, .remote("work"))?.message == stderr)
        #expect(Support.failure(registry, .remote("work"))?.hint == hint)
        registry.shutdown()
    }
}
