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
            if !hosts.contains(where: { $0.hostID == selected }) { select(.local) }
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
        Task { _ = try? await daemon.connectHost(name) }
    }

    func retry() {
        guard case .remote(let name) = selected else { return }
        Task { _ = try? await daemon.connectHost(name) }
    }

    func receive(_ row: LeoHostRow) {
        if let index = hosts.firstIndex(where: { $0.name == row.name }) { hosts[index] = row } else { hosts.append(row) }
    }

    private static let localhost = LeoHostRow(name: "localhost", local: true, state: .local)
}
