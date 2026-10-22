import Foundation
@testable import Ghostty
@testable import LeoKit

/// A scripted `LeoMachineClientResolving`: each host has its own daemon and
/// generation, so a test can reconnect, fail or bump one machine and watch
/// the others.
@MainActor final class FakeMachineClients: LeoMachineClientResolving {
    private var daemons: [LeoHostID: any LeoDaemonClient]
    private var generations: [LeoHostID: Int] = [:]
    private var configurations: [LeoHostID: LeoHostConfiguration]

    init(daemons: [LeoHostID: any LeoDaemonClient] = [:], configurations: [LeoHostConfiguration] = []) {
        self.daemons = daemons
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { (.remote($0.name), $0) })
    }

    convenience init(daemon: any LeoDaemonClient, host: LeoHostID = .local) {
        self.init(daemons: [host: daemon])
    }

    func daemon(for host: LeoHostID) -> (any LeoDaemonClient)? { daemons[host] }
    func generation(for host: LeoHostID) -> Int { generations[host, default: 0] }
    func configuration(for host: LeoHostID) -> LeoHostConfiguration? { configurations[host] }

    /// `host`'s connection came up (or was replaced): a new daemon, a new generation.
    func connect(_ host: LeoHostID, _ daemon: any LeoDaemonClient) {
        daemons[host] = daemon
        generations[host, default: 0] += 1
    }

    /// `host`'s connection dropped: no daemon, a new generation.
    func disconnect(_ host: LeoHostID) {
        daemons[host] = nil
        generations[host, default: 0] += 1
    }

    func configure(_ configuration: LeoHostConfiguration) { configurations[.remote(configuration.name)] = configuration }
}
