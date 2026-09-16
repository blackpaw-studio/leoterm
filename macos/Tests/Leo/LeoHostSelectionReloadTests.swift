import Darwin
import Foundation
import Testing

@testable import Ghostty

/// `LeoHostSelection.reloadHostsAfterEdit()` -- called after the Hosts
/// editor sheet saves.
@Suite(.serialized)
@MainActor struct LeoHostSelectionReloadTests {
    @Test func removingTheSelectedHostRevertsSelectionToLocalhost() async throws {
        let work = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let suiteDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [work], transport: LeoAlwaysHealthyTransport(), defaults: suiteDefaults)
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))
        let expectedPath = LeoHostSelectionTestSupport.expectedLocalSocketPath(work)
        await LeoHostSelectionTestSupport.awaitConnected(selection, expectedPath)

        try LeoHostStore(defaults: suiteDefaults).save([])
        selection.reloadHostsAfterEdit()

        #expect(selection.selected == .local)
        #expect(selection.state == .connected(socketPath: LeoHostSelectionTestSupport.localSocketPath))

        selection.shutdown()
    }

    @Test func editingTheSelectedHostsTargetReselectsExactlyOnce() async throws {
        let work = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let suiteDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [work], transport: LeoAlwaysHealthyTransport(), defaults: suiteDefaults)
        await selection.start(flavor: .socketEvents)

        let pidFile1 = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile1)
        selection.select(.remote("work"))
        let pid1 = try await LeoHostSelectionTestSupport.awaitPID(pidFile1)

        let editedWork = LeoHostConfiguration(id: work.id, name: "work", sshTarget: "evan@work-new", remoteSocketPath: "/remote/leo.sock")
        try LeoHostStore(defaults: suiteDefaults).save([editedWork])

        let pidFile2 = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile2)
        selection.reloadHostsAfterEdit()
        let pid2 = try await LeoHostSelectionTestSupport.awaitPID(pidFile2)
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil)

        #expect(pid2 != pid1, "a changed configuration must tear down and reconnect with a fresh tunnel")
        #expect(Darwin.kill(pid1, 0) == -1 && errno == ESRCH)

        // "Reselected exactly once": no further relaunch happens on its own.
        for _ in 0..<30 { await Task.yield() }
        #expect(Darwin.kill(pid2, 0) == 0, "the single reselect's tunnel must still be the live one")

        selection.shutdown()
    }

    @Test func editingAnUnrelatedHostDoesNotReselect() async throws {
        let work = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let other = LeoHostConfiguration(name: "other", sshTarget: "evan@other")
        let suiteDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let selection = LeoHostSelectionTestSupport.makeSelection(hosts: [work, other], transport: LeoAlwaysHealthyTransport(), defaults: suiteDefaults)
        await selection.start(flavor: .socketEvents)

        let pidFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        selection.select(.remote("work"))
        let pid = try await LeoHostSelectionTestSupport.awaitPID(pidFile)
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil)

        let editedOther = LeoHostConfiguration(id: other.id, name: "other", sshTarget: "evan@other-new")
        try LeoHostStore(defaults: suiteDefaults).save([work, editedOther])

        selection.reloadHostsAfterEdit()

        for _ in 0..<30 { await Task.yield() }
        #expect(Darwin.kill(pid, 0) == 0, "editing an unrelated host must not tear down the selected host's tunnel")
        #expect(selection.selected == .remote("work"))
        #expect(selection.hosts.first { $0.name == "other" }?.sshTarget == "evan@other-new", "hosts must still reload so the picker reflects the edit")

        selection.shutdown()
    }
}
