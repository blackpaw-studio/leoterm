import Combine
import Foundation
import LeoKit

/// What per-host actions need from the machine layer: the daemon a host's
/// connection currently talks to, the generation of that connection, and the
/// host's configuration. Machines connect at once, so every call is keyed by
/// the row's host; there is no "selected" connection.
///
/// `LeoRegistryMachineClients` adapts `LeoMachineRegistry` to it.
@MainActor protocol LeoMachineClientResolving: AnyObject {
    /// The client for `host`'s live connection, or nil while that host has
    /// none (connecting, failed, disabled or unknown).
    func daemon(for host: LeoHostID) -> (any LeoDaemonClient)?
    /// Bumped whenever `host`'s connection is replaced or torn down, so a
    /// completion captured before the bump is dropped. Never affected by
    /// another host's connection.
    func generation(for host: LeoHostID) -> Int
    /// The saved configuration of a remote `host`; nil for This Mac.
    func configuration(for host: LeoHostID) -> LeoHostConfiguration?
    /// Fires with a host whenever its client is bound or dropped, so a view
    /// waiting on a connection that is up but whose client isn't built yet
    /// (the Settings window) can look again.
    var clientChanges: AnyPublisher<LeoHostID, Never> { get }
}

extension LeoMachineClientResolving {
    var clientChanges: AnyPublisher<LeoHostID, Never> { Empty().eraseToAnyPublisher() }
}
