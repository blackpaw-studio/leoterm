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
            localSocketPath: expectedLocalPath, remoteSocketPath: "/remote/leo.sock"
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
