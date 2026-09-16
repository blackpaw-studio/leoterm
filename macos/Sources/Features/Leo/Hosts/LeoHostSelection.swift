import Combine
import Foundation

@MainActor final class LeoHostSelection: ObservableObject {
    @Published private(set) var hosts: [LeoHostRow] = [LeoHostRow(name: "localhost", local: true, state: .local)]
    @Published private(set) var selected: LeoHostID
    @Published private(set) var flavor: LeoAPIFlavor = .legacy

    private let daemon: any LeoDaemonClient
    private let defaults: UserDefaults
    private let installTarget: (LeoHostID) -> Void

    init(daemon: any LeoDaemonClient, defaults: UserDefaults,
         installTarget: @escaping (LeoHostID) -> Void) {
        self.daemon = daemon
        self.defaults = defaults
        self.installTarget = installTarget
        if let value = defaults.string(forKey: "leo.selectedHost"), value != "localhost" {
            selected = .remote(value)
        } else {
            selected = .local
        }
    }

    var legacyTooltip: String? { flavor == .legacy ? "leo 0.29+ required for remote hosts" : nil }
    var selectedRow: LeoHostRow? { hosts.first { $0.hostID == selected } }
    var sshHint: String? {
        guard let row = selectedRow, row.code == "ssh_auth_required" || row.code == "ssh_host_key_unknown",
              let ssh = row.ssh else { return nil }
        return "Run `ssh \(ssh)` once in a terminal"
    }

    func start(flavor: LeoAPIFlavor) async {
        self.flavor = flavor
        guard flavor == .hub else { hosts = [Self.localhost]; select(.local); return }
        do {
            hosts = try await daemon.hosts()
            if hosts.contains(where: { $0.hostID == selected }) {
                installTarget(selected)
            } else {
                select(.local)
            }
        } catch {
            hosts = [Self.localhost]
        }
    }

    func select(_ host: LeoHostID) {
        selected = host
        defaults.set(host.displayName, forKey: "leo.selectedHost")
        installTarget(host)
        guard case .remote(let name) = host,
              let row = hosts.first(where: { $0.hostID == host }), row.state == .disconnected else { return }
        Task { await attemptConnect(name) }
    }

    func retry() {
        guard case .remote(let name) = selected else { return }
        Task { await attemptConnect(name) }
    }

    /// Connects a remote host and applies the outcome immediately, instead of
    /// discarding it: a successful row is merged in (Retry no longer depends
    /// on an SSE host_state_changed event to reflect it), and a thrown error
    /// marks the row as errored with the daemon's message/code so Retry can
    /// surface it right away.
    private func attemptConnect(_ name: String) async {
        do {
            let row = try await daemon.connectHost(name)
            receive(row)
        } catch {
            guard let index = hosts.firstIndex(where: { $0.name == name }) else { return }
            let existing = hosts[index]
            hosts[index] = LeoHostRow(
                name: existing.name,
                local: existing.local,
                isDefault: existing.isDefault,
                ssh: existing.ssh,
                state: .error,
                error: Self.message(error),
                code: Self.code(error),
                connectedAt: existing.connectedAt
            )
        }
    }

    private static func message(_ error: Error) -> String {
        if case let LeoDaemonError.daemon(_, message, _) = error { return message }
        return error.localizedDescription
    }

    private static func code(_ error: Error) -> String? {
        if case let LeoDaemonError.daemon(code, _, _) = error { return code }
        return nil
    }

    func receive(_ row: LeoHostRow) {
        if let index = hosts.firstIndex(where: { $0.name == row.name }) {
            let existing = hosts[index]
            hosts[index] = LeoHostRow(
                name: row.name,
                local: row.local || existing.local,
                isDefault: row.isDefault || existing.isDefault,
                ssh: row.ssh ?? existing.ssh,
                state: row.state,
                error: row.error,
                code: row.code,
                connectedAt: row.connectedAt ?? existing.connectedAt
            )
        } else {
            hosts.append(row)
        }
    }

    private static let localhost = LeoHostRow(name: "localhost", local: true, state: .local)
}
