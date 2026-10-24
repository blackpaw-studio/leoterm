import Combine
import Foundation
import LeoKit

/// `LeoMachineClientResolving` over `LeoMachineRegistry`: each machine's
/// daemon client, bound by `LeoRuntime` once that machine's connection is up
/// and its client built, and handed out only while that same connection is
/// still the machine's live one. Generations and configurations are the
/// registry's own, per machine.
@MainActor final class LeoRegistryMachineClients: LeoMachineClientResolving {
    private let registry: LeoMachineRegistry
    private var bound: [LeoHostID: (generation: Int, daemon: any LeoDaemonClient)] = [:]
    private let changes = PassthroughSubject<LeoHostID, Never>()

    var clientChanges: AnyPublisher<LeoHostID, Never> { changes.eraseToAnyPublisher() }

    init(registry: LeoMachineRegistry) {
        self.registry = registry
    }

    /// `host`'s client for its connection `generation`.
    func bind(_ daemon: any LeoDaemonClient, host: LeoHostID, generation: Int) {
        bound[host] = (generation, daemon)
        changes.send(host)
    }

    /// Forgets `host`'s client, for a machine that left.
    func unbind(_ host: LeoHostID) {
        bound[host] = nil
        changes.send(host)
    }

    func daemon(for host: LeoHostID) -> (any LeoDaemonClient)? {
        guard let client = bound[host], client.generation == registry.generation(for: host),
              registry.status(for: host) == .connected else { return nil }
        return client.daemon
    }

    func generation(for host: LeoHostID) -> Int { registry.generation(for: host) }

    func configuration(for host: LeoHostID) -> LeoHostConfiguration? { registry.configuration(for: host) }
}
