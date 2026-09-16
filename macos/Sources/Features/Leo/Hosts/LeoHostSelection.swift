import Combine
import Foundation

/// TEMPORARY (sub-round 1 of the app-owned-tunnel rewrite, see
/// `docs/superpowers/specs/2026-09-15-leo-v2-agent-manager.md` §3.2): the
/// daemon-owned `/hosts` hub API is gone, and app-owned SSH tunnels
/// (`LeoTunnel`/`LeoHostStore`/`LeoSSHCommand`) aren't wired in here yet --
/// that lands in sub-round 2. Until then, selecting or retrying any remote
/// host synchronously marks it `.error` with no daemon or network call of
/// any kind.
@MainActor final class LeoHostSelection: ObservableObject {
    @Published private(set) var hosts: [LeoHostRow] = [LeoHostRow(name: "localhost", local: true, state: .local)]
    @Published private(set) var selected: LeoHostID
    @Published private(set) var flavor: LeoAPIFlavor = .legacy

    private let daemon: any LeoDaemonClient
    private let defaults: UserDefaults
    private let hostStateTarget: (LeoHostRow) -> Void
    private let installTarget: (LeoHostID) -> Void

    init(daemon: any LeoDaemonClient, defaults: UserDefaults,
         hostStateTarget: @escaping (LeoHostRow) -> Void = { _ in },
         installTarget: @escaping (LeoHostID) -> Void) {
        self.daemon = daemon
        self.defaults = defaults
        self.hostStateTarget = hostStateTarget
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
        hosts = [Self.localhost]
        select(.local)
    }

    func select(_ host: LeoHostID) {
        selected = host
        defaults.set(host.displayName, forKey: "leo.selectedHost")
        installTarget(host)
        guard case .remote(let name) = host else { return }
        markUnavailable(name)
    }

    func retry() {
        guard case .remote(let name) = selected else { return }
        markUnavailable(name)
    }

    private func markUnavailable(_ name: String) {
        let existing = hosts.first { $0.name == name }
        let errorRow = LeoHostRow(
            name: name,
            ssh: existing?.ssh,
            state: .error,
            error: "Remote hosts are not connected yet",
            code: nil
        )
        receive(errorRow)
        hostStateTarget(errorRow)
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
