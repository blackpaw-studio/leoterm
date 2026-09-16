import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Generation-race / teardown-serialization coverage for `LeoHostSelection`:
/// launch, probe, and termination are gated independently (`fake_ssh.py` env
/// hooks + `LeoGatedTransport`) so a boundary (e.g. "the old child is dead
/// before the new one launches") can be asserted precisely.
@Suite(.serialized)
@MainActor struct LeoHostSelectionRaceTests {
    /// The core teardown-serialization fix: a rapid A->B->A must never have
    /// two live children at once, at ANY boundary -- including the second
    /// transition, whose "previous tunnel" (B) may not even be assigned yet
    /// when the third `select()` fires.
    @Test func aToBToAHasAtMostOneLiveChildAtEveryBoundaryAndOnlyTheLastGenerationPublishes() async throws {
        let transport = LeoGatedTransport()
        let a = LeoHostConfiguration(name: "a", sshTarget: "evan@a", remoteSocketPath: "/remote/leo.sock")
        let b = LeoHostConfiguration(name: "b", sshTarget: "evan@b", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [a, b], transport: transport)
        await selection.start(flavor: .socketEvents)

        let pidFileA1 = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFileA1)
        selection.select(.remote("a"))
        let pidA1 = try await LeoHostSelectionTestSupport.awaitPID(pidFileA1)

        let pidFileB = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFileB)
        selection.select(.remote("b"))
        let pidB = try await LeoHostSelectionTestSupport.awaitPID(pidFileB)
        #expect(Darwin.kill(pidA1, 0) == -1 && errno == ESRCH, "a's first child must be dead before b launches")

        let pidFileA2 = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFileA2)
        selection.select(.remote("a"))
        let pidA2 = try await LeoHostSelectionTestSupport.awaitPID(pidFileA2)
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil)

        #expect(Darwin.kill(pidB, 0) == -1 && errno == ESRCH, "b's child must be dead before a's second launch")
        #expect(pidA2 != pidA1)

        await transport.open()
        let expectedAPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(a)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedAPath)
        #expect(selection.selected == .remote("a"))

        selection.shutdown()
        #expect(Darwin.kill(pidA2, 0) == -1 && errno == ESRCH)
    }

    @Test func retryWhileConnectingReplacesTheLaunchedChildWithANewPID() async throws {
        let transport = LeoGatedTransport()
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: transport)
        await selection.start(flavor: .socketEvents)

        let pidFile1 = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile1)
        selection.select(.remote("work"))
        let pid1 = try await LeoHostSelectionTestSupport.awaitPID(pidFile1)
        #expect(selection.state == .connecting)

        let pidFile2 = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile2)
        selection.retry()
        let pid2 = try await LeoHostSelectionTestSupport.awaitPID(pidFile2)
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil)

        #expect(pid2 != pid1)
        #expect(Darwin.kill(pid1, 0) == -1 && errno == ESRCH)

        await transport.open()
        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)

        selection.shutdown()
    }

    /// A newer selection supersedes this one while its health probe is
    /// gated (still parked): the superseded tunnel must be terminated, its
    /// orphan record cleared, and it must never publish `.connected` even
    /// though its own probe eventually succeeds.
    @Test func staleSuccessWhileProbeGatedNeverPublishesConnectedAndClearsTheOrphanRecord() async throws {
        let transport = LeoGatedTransport()
        let suiteDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let orphanStore = LeoTunnelOrphanStore(defaults: suiteDefaults)
        let stale = LeoHostConfiguration(name: "stale", sshTarget: "evan@stale", remoteSocketPath: "/remote/leo.sock")
        let fresh = LeoHostConfiguration(name: "fresh", sshTarget: "evan@fresh", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [stale, fresh], transport: transport, defaults: suiteDefaults, orphanStore: orphanStore
        )
        await selection.start(flavor: .socketEvents)

        let staleFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", staleFile)
        selection.select(.remote("stale"))
        let stalePID = try await LeoHostSelectionTestSupport.awaitPID(staleFile)
        try #require(orphanStore.current()?.pid == stalePID)

        let freshFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", freshFile)
        selection.select(.remote("fresh"))
        _ = try await LeoHostSelectionTestSupport.awaitPID(freshFile)
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil)

        // The stale probe (still parked in the gate from `select(.remote("stale"))`)
        // now succeeds -- after it has already been superseded.
        await transport.open()
        let expectedFreshPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(fresh)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedFreshPath)

        #expect(Darwin.kill(stalePID, 0) == -1 && errno == ESRCH)
        #expect(orphanStore.current()?.pid != stalePID)
        if case .connected(let path) = selection.state {
            #expect(path == expectedFreshPath)
        } else {
            Issue.record("expected .connected(fresh), got \(selection.state)")
        }

        selection.shutdown()
    }

    /// The child dying while its probe is still gated (never having
    /// answered healthy) must surface as `.failed` via the normal
    /// `exitedBeforeReady` error path.
    @Test func deathWhileProbeStillGatedPublishesFailed() async throws {
        let transport = LeoGatedTransport()
        let pidFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: transport)
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let pid = try await LeoHostSelectionTestSupport.awaitPID(pidFile)
        _ = Darwin.kill(pid, SIGKILL)
        await transport.open()

        await LeoHostSelectionTestSupport.awaitFailed(selection)
    }

    @Test func tunnelDeathAfterConnectedPublishesFailedWithoutRelaunching() async throws {
        let pidFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: LeoAlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)
        let pid = try await LeoHostSelectionTestSupport.awaitPID(pidFile)
        let launchedContent = try String(contentsOfFile: pidFile, encoding: .utf8)

        _ = Darwin.kill(pid, SIGKILL)
        await LeoHostSelectionTestSupport.awaitFailed(selection)

        // No relaunch: the pid file's content (a fresh launch's proof) must
        // never change without an explicit retry.
        for _ in 0..<20 { await Task.yield() }
        let laterContent = try? String(contentsOfFile: pidFile, encoding: .utf8)
        #expect(laterContent == launchedContent, "a new child relaunched without an explicit retry")
    }

    @Test func shutdownSynchronouslyTerminatesTheCurrentTunnel() async throws {
        let pidFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: LeoAlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)
        let pid = try await LeoHostSelectionTestSupport.awaitPID(pidFile)

        selection.shutdown()

        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func shutdownWhileConnectingLeavesNoChildAliveAndBlocksFurtherLaunches() async throws {
        let transport = LeoGatedTransport()
        let pidFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [configuration], transport: transport)
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))
        let pid = try await LeoHostSelectionTestSupport.awaitPID(pidFile)

        selection.shutdown()
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)

        let contentAtShutdown = try String(contentsOfFile: pidFile, encoding: .utf8)
        selection.select(.remote("work"))
        for _ in 0..<20 { await Task.yield() }
        let laterContent = try? String(contentsOfFile: pidFile, encoding: .utf8)
        #expect(laterContent == contentAtShutdown, "select() after shutdown() must never launch a new child")
    }

    @Test func orphanRecordIsWrittenImmediatelyAtLaunchAndClearedOnExit() async throws {
        let pidFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let transport = LeoGatedTransport()
        let suiteDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let orphanStore = LeoTunnelOrphanStore(defaults: suiteDefaults)
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], transport: transport, defaults: suiteDefaults, orphanStore: orphanStore
        )
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(configuration)
        let pid = try await LeoHostSelectionTestSupport.awaitPID(pidFile)
        // Recorded at launch -- before the (still-gated) readiness probe
        // has answered at all.
        #expect(selection.state == .connecting)
        let record = try #require(orphanStore.current())
        #expect(record.pid == pid)
        #expect(record.socketPath == expectedPath)

        await transport.open()
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)

        selection.shutdown()
        await awaitCondition(message: "orphan record was never cleared after shutdown") { orphanStore.current() == nil }
    }
}
