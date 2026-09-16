import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoHostSelectionTests {
    @Test func disconnectedSelectionConnectsOnceWhileConnectedSelectionDoesNot() async throws {
        let daemon = SelectionDaemon(hosts: [
            .init(name: "localhost", local: true, state: .local),
            .init(name: "sleeping", ssh: "evan@sleeping", state: .disconnected),
            .init(name: "awake", ssh: "evan@awake", state: .connected)
        ])
        let selection = LeoHostSelection(daemon: daemon, defaults: defaults()) { _ in }
        await selection.start(flavor: .hub)
        selection.select(.remote("sleeping"))
        await awaitCondition { await daemon.connects == ["sleeping"] }
        selection.select(.remote("awake"))
        #expect(await daemon.connects == ["sleeping"])
    }

    @Test func retryConnectsSelectedHostAndSSHErrorProvidesQuotedTarget() async throws {
        let daemon = SelectionDaemon(hosts: [
            .init(name: "localhost", local: true, state: .local),
            .init(name: "work", ssh: "evan@host name", state: .error,
                  error: "Permission denied", code: "ssh_auth_required")
        ])
        let selection = LeoHostSelection(daemon: daemon, defaults: defaults()) { _ in }
        await selection.start(flavor: .hub)
        selection.select(.remote("work"))
        #expect(selection.sshHint == "Run `ssh evan@host name` once in a terminal")
        #expect(try LeoCommandLauncher.sshHintCommand(target: selection.selectedRow?.ssh ?? "") == "ssh 'evan@host name'")
        selection.retry()
        await awaitCondition { await daemon.connects == ["work"] }
    }

    @Test func legacyModeShowsOnlyLocalhostAndUpgradeHint() async {
        let daemon = SelectionDaemon(hosts: [.init(name: "work", state: .connected)])
        let selection = LeoHostSelection(daemon: daemon, defaults: defaults()) { _ in }
        await selection.start(flavor: .legacy)
        #expect(selection.hosts.map(\.name) == ["localhost"])
        #expect(selection.legacyTooltip == "leo 0.29+ required for remote hosts")
        #expect(await daemon.hostCallCount == 0)
    }

    private func defaults() -> UserDefaults {
        let suite = "LeoHostSelectionTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}

private actor SelectionDaemon: LeoDaemonClient {
    let rows: [LeoHostRow]
    private(set) var connects: [String] = []
    private(set) var hostCallCount = 0

    init(hosts: [LeoHostRow]) { rows = hosts }
    func hosts() -> [LeoHostRow] { hostCallCount += 1; return rows }
    func connectHost(_ name: String) -> LeoHostRow {
        connects.append(name)
        return rows.first { $0.name == name } ?? .init(name: name, state: .connecting)
    }
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
