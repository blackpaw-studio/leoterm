import Combine
import Foundation
import LeoKit

/// One row of the spawn sheet's Machine picker.
struct SpawnMachineOption: Equatable, Identifiable {
    let host: LeoHostID
    let status: LeoMachineStatus

    var id: LeoHostID { host }
    var isSelectable: Bool { status.isSelectable }
    var title: String { Self.title(for: host) }

    static func title(for host: LeoHostID) -> String { host == .local ? "This Mac" : host.displayName }

    /// Why the machine can't take a spawn right now; nil when it can.
    var detail: String? {
        switch status {
        case .connected: nil
        case .connecting: "Connecting…"
        case .failed(let reason): "Unreachable · \(reason)"
        case .disabled: "Disabled"
        }
    }
}

/// What the spawn sheet reads from the app, per machine. The sheet re-reads
/// them whenever the chosen machine changes.
struct SpawnMachineFeeds {
    /// The machines to offer, in order, with where each one stands.
    var machines: AnyPublisher<[SpawnMachineOption], Never>
    var templateList: (LeoHostID) -> AnyPublisher<LeoTemplateListState, Never>
    var environmentCatalog: (LeoHostID) -> AnyPublisher<LeoEnvironmentCatalogState, Never>
    /// The machine's daemon advertises `agent_environments`.
    var environmentsSupported: (LeoHostID) -> AnyPublisher<Bool, Never>
    /// The user switched to this machine: refetch its templates and
    /// environment catalog.
    var reload: (LeoHostID) -> Void

    /// The sidebar model's machines and `LeoAgentActions`' per-machine lists.
    @MainActor static func live(sidebar: LeoSidebarModel, actions: LeoAgentActions) -> SpawnMachineFeeds {
        SpawnMachineFeeds(
            machines: machines(of: sidebar),
            templateList: { host in actions.$templateLists.map { $0[host] ?? .loading }.removeDuplicates().eraseToAnyPublisher() },
            environmentCatalog: { host in
                actions.$environmentCatalogs.map { $0[host] ?? .loading }.removeDuplicates().eraseToAnyPublisher()
            },
            environmentsSupported: { host in
                sidebar.$snapshots.map { $0[host]?.features.contains(.agentEnvironments) ?? false }.removeDuplicates().eraseToAnyPublisher()
            },
            reload: { actions.hostConnected($0) }
        )
    }

    /// The sidebar's machines in order. This Mac is always there; a remote
    /// the registry hasn't reported yet is still connecting.
    @MainActor private static func machines(of sidebar: LeoSidebarModel) -> AnyPublisher<[SpawnMachineOption], Never> {
        Publishers.CombineLatest(sidebar.$machineOrder, sidebar.$machineStatuses)
            .map { order, statuses in
                (order.isEmpty ? [.local] : order).map { host in
                    SpawnMachineOption(host: host, status: statuses[host] ?? (host == .local ? .connected : .connecting))
                }
            }
            .eraseToAnyPublisher()
    }
}

/// `leo.lastSpawnMachine`: the machine the last successful spawn ran on.
/// Spelled as `LeoHostID.displayName` ("localhost" for This Mac), as the
/// settings migration writes it.
struct SpawnMachineMemory {
    static let key = LeoMachineDefaultsMigration.lastSpawnMachineKey

    let defaults: UserDefaults

    var lastUsed: LeoHostID? {
        defaults.string(forKey: Self.key).map { $0 == LeoHostID.local.displayName ? .local : .remote($0) }
    }

    func remember(_ host: LeoHostID) {
        defaults.set(host.displayName, forKey: Self.key)
    }
}
