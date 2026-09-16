import Foundation
import Testing

@testable import Ghostty

/// TEMPORARY (sub-round 1 of the app-owned-tunnel rewrite): `LeoHostSelection`
/// no longer talks to any daemon -- the `/hosts` hub API is gone and SSH
/// tunnel wiring lands in sub-round 2. These tests cover only the current,
/// intentionally minimal behavior (every remote host synchronously fails)
/// and will be replaced wholesale once tunnels land.
@MainActor struct LeoHostSelectionTests {
    @Test func localhostIsSelectedByDefaultAndNeverContactsTheDaemon() async {
        let daemon = NeverCalledDaemon()
        let selection = LeoHostSelection(daemon: daemon, defaults: defaults()) { _ in }
        await selection.start(flavor: .legacy)
        #expect(selection.selected == .local)
        #expect(selection.hosts.map(\.name) == ["localhost"])
    }

    @Test func legacyModeShowsUpgradeHint() async {
        let selection = LeoHostSelection(daemon: NeverCalledDaemon(), defaults: defaults()) { _ in }
        await selection.start(flavor: .legacy)
        #expect(selection.legacyTooltip == "leo 0.29+ required for remote hosts")
    }

    @Test func socketEventsModeHasNoUpgradeHint() async {
        let selection = LeoHostSelection(daemon: NeverCalledDaemon(), defaults: defaults()) { _ in }
        await selection.start(flavor: .socketEvents)
        #expect(selection.legacyTooltip == nil)
    }

    @Test func selectingARemoteHostFailsSynchronouslyWithoutADaemonCall() async {
        var received: [LeoHostRow] = []
        let selection = LeoHostSelection(daemon: NeverCalledDaemon(), defaults: defaults(), hostStateTarget: { received.append($0) }, installTarget: { _ in })
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        #expect(selection.selected == .remote("work"))
        #expect(selection.hosts.first { $0.name == "work" }?.state == .error)
        #expect(received.last?.state == .error)
    }

    @Test func retryingARemoteHostFailsSynchronouslyAgain() async {
        let selection = LeoHostSelection(daemon: NeverCalledDaemon(), defaults: defaults()) { _ in }
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))
        let firstError = selection.hosts.first { $0.name == "work" }?.error

        selection.retry()

        #expect(selection.hosts.first { $0.name == "work" }?.error == firstError)
    }

    @Test func receiveMergesRowsPreservingExistingConfigurationMetadata() async throws {
        let selection = LeoHostSelection(daemon: NeverCalledDaemon(), defaults: defaults()) { _ in }
        await selection.start(flavor: .socketEvents)
        selection.receive(.init(name: "work", isDefault: true, ssh: "evan@work", state: .connected))

        selection.receive(.init(name: "work", state: .error, error: "denied", code: "ssh_auth_required"))

        let row = try #require(selection.hosts.first { $0.name == "work" })
        #expect(row.ssh == "evan@work")
        #expect(row.isDefault == true)
        #expect(row.state == .error)
    }

    private func defaults() -> UserDefaults {
        let suite = "LeoHostSelectionTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}

/// A daemon fake that traps if `LeoHostSelection` ever calls it -- the
/// temporary implementation must never make a daemon call for a remote host.
private actor NeverCalledDaemon: LeoDaemonClient {
    func listAgents() throws -> [LeoAgent] { [] }
    func spawn(_: LeoSpawnRequest) throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func start(_: String) {}
    func stop(_: String, wakeOnMessage _: Bool?) {}
    func restart(_: String) throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_: String) {}
    func setTemplate(_: String, template _: String) {}
    func rename(_: String, newName _: String) throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_: String, force _: Bool?, deleteBranch _: Bool?) {}
    func deletePlan(_: String) throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_: String, lines _: Int?) -> String { "" }
}
