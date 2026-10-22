import Foundation
import LeoKit

/// `LeoMachineClientResolving` over today's single `LeoHostSelection`, until
/// `LeoMachineRegistry` replaces it: one daemon is bound at a time (the
/// selected host's, once its tunnel is up), and the generation is the
/// selection's. Hosts other than the bound one have no client.
@MainActor final class LeoSelectionMachineClients: LeoMachineClientResolving {
    private let hostSelection: LeoHostSelection
    private var bound: (daemon: any LeoDaemonClient, host: LeoHostID)

    init(hostSelection: LeoHostSelection, daemon: any LeoDaemonClient, host: LeoHostID = .local) {
        self.hostSelection = hostSelection
        bound = (daemon, host)
    }

    /// `LeoRuntime` calls this each time the selection reports a new
    /// connected socket (a new host's tunnel came up, or back to localhost).
    /// `LeoHostSelection.selected` moves the moment a host is picked, but
    /// the bound daemon only once its tunnel is up (and never, if it fails),
    /// so a spawn or action for the new host is refused until then (B-176).
    func bind(_ daemon: any LeoDaemonClient, host: LeoHostID) {
        bound = (daemon, host)
    }

    func daemon(for host: LeoHostID) -> (any LeoDaemonClient)? {
        bound.host == host ? bound.daemon : nil
    }

    func generation(for _: LeoHostID) -> Int { hostSelection.generationToken }

    func configuration(for host: LeoHostID) -> LeoHostConfiguration? {
        guard case .remote(let name) = host else { return nil }
        return hostSelection.hosts.first { $0.name == name }
    }
}
