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

    @Test func persistedRemoteSelectionInstallsAfterHostsLoad() async {
        let values = defaults()
        values.set("work", forKey: "leo.selectedHost")
        var installed: [LeoHostID] = []
        let selection = LeoHostSelection(
            daemon: SelectionDaemon(hosts: [.init(name: "work", ssh: "evan@work", state: .connected)]),
            defaults: values,
            installTarget: { installed.append($0) }
        )

        await selection.start(flavor: .hub)

        #expect(installed == [.remote("work")])
    }

    @Test func hostStateUpdatesPreserveConfigurationMetadata() async throws {
        let selection = LeoHostSelection(daemon: SelectionDaemon(hosts: [
            .init(name: "work", isDefault: true, ssh: "evan@work", state: .connected)
        ]), defaults: defaults()) { _ in }
        await selection.start(flavor: .hub)

        selection.receive(.init(name: "work", state: .error, error: "denied", code: "ssh_auth_required"))

        let row = try #require(selection.hosts.first { $0.name == "work" })
        #expect(row.ssh == "evan@work")
        #expect(row.isDefault)
        #expect(row.state == .error)
    }

    @Test func retrySuccessMergesTheReturnedRowWithoutWaitingForSSE() async throws {
        let daemon = SelectionDaemon(hosts: [
            .init(name: "localhost", local: true, state: .local),
            .init(name: "work", ssh: "evan@work", state: .error, error: "Permission denied", code: "ssh_auth_required")
        ])
        let selection = LeoHostSelection(daemon: daemon, defaults: defaults()) { _ in }
        await selection.start(flavor: .hub)
        selection.select(.remote("work"))

        await daemon.setConnectResult(.success(.init(name: "work", ssh: "evan@work", state: .connected, connectedAt: "now")))
        selection.retry()

        await awaitCondition(message: "Retry's successful result was never merged into hosts") {
            await selection.hosts.first { $0.name == "work" }?.state == .connected
        }
        #expect(selection.hosts.first { $0.name == "work" }?.connectedAt == "now")
        #expect(await daemon.connects == ["work"])
    }

    @Test func retryFailureMarksTheRowAsErroredWithMessageAndCode() async throws {
        let daemon = SelectionDaemon(hosts: [
            .init(name: "localhost", local: true, state: .local),
            .init(name: "work", ssh: "evan@work", state: .error, error: "stale", code: "stale_code")
        ])
        let selection = LeoHostSelection(daemon: daemon, defaults: defaults()) { _ in }
        await selection.start(flavor: .hub)
        selection.select(.remote("work"))

        await daemon.setConnectResult(.failure(LeoDaemonError.daemon(code: "ssh_auth_required", message: "Permission denied", matches: [])))
        selection.retry()

        await awaitCondition(message: "Retry's failure was never reflected in hosts") {
            await selection.hosts.first { $0.name == "work" }?.error == "Permission denied"
        }
        let row = try #require(selection.hosts.first { $0.name == "work" })
        #expect(row.state == .error)
        #expect(row.code == "ssh_auth_required")
        #expect(row.ssh == "evan@work", "Retry's failure must preserve existing configuration metadata")
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
    private var connectResult: Result<LeoHostRow, Error>?

    init(hosts: [LeoHostRow]) { rows = hosts }
    func hosts() -> [LeoHostRow] { hostCallCount += 1; return rows }
    func setConnectResult(_ result: Result<LeoHostRow, Error>) { connectResult = result }
    func connectHost(_ name: String) throws -> LeoHostRow {
        connects.append(name)
        if let connectResult { return try connectResult.get() }
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
