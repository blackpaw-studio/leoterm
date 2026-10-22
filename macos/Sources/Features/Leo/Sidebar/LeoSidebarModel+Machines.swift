import Foundation
import LeoKit

/// One machine's block of the sidebar: its connection, its own sections
/// (Needs You, Pinned, status groups) and the header facts.
struct LeoMachineSection: Identifiable, Equatable {
    let host: LeoHostID
    /// `.loading` until the machine's first snapshot.
    let connectivity: LeoConnectivity
    let sections: [LeoSidebarSection]
    /// The whole machine is folded to its header.
    let isCollapsed: Bool
    let attentionCount: Int
    let features: LeoDaemonFeatures
    /// Nil while there is no sample (disconnected, or a daemon without stats).
    let stats: LeoMachineStats?

    var id: LeoHostID { host }
}

/// The sidebar groups agents by machine: This Mac first, then the others
/// in Settings order.
extension LeoSidebarModel {
    /// The machines to show: the configured order, then (before any is
    /// configured) any machine that has delivered, This Mac first.
    var machineHosts: [LeoHostID] { Self.machineHosts(order: machineOrder, snapshots: snapshots) }

    /// `machineHosts` for an `order` and `snapshots` just emitted.
    nonisolated static func machineHosts(order: [LeoHostID], snapshots: [LeoHostID: LeoSidebarSnapshot]) -> [LeoHostID] {
        let configured = Set(order)
        let delivered = snapshots.keys.filter { !configured.contains($0) }
            .sorted { ($0 == .local ? "" : $0.displayName) < ($1 == .local ? "" : $1.displayName) }
        return order + delivered
    }

    var machineSections: [LeoMachineSection] {
        machineHosts.map { host in
            let snapshot = snapshots[host]
            return LeoMachineSection(
                host: host,
                connectivity: snapshot?.connectivity ?? .loading,
                sections: LeoSidebarLayout.sections(
                    rows: snapshot?.rows ?? [], query: query, preferences: preferences, host: host
                ),
                isCollapsed: isMachineCollapsed(host),
                attentionCount: snapshot?.attentionCount ?? 0,
                features: snapshot?.features ?? .none,
                stats: machineStats[host]
            )
        }
    }

    func isMachineCollapsed(_ host: LeoHostID) -> Bool { preferences.collapsedMachines.contains(host) }

    /// Each shown machine's connectivity, in display order; `.loading`
    /// until its first snapshot.
    var machineConnectivity: [(host: LeoHostID, connectivity: LeoConnectivity)] {
        machineHosts.map { ($0, snapshots[$0]?.connectivity ?? .loading) }
    }

    var hasConnectedMachine: Bool { machineConnectivity.contains { $0.connectivity == .connected } }

    /// Whether `host` is a machine to show; before any are configured,
    /// every machine is.
    func isShown(_ host: LeoHostID) -> Bool { machineOrder.isEmpty || machineOrder.contains(host) }
}
