import Foundation
import LeoKit

/// What the plugin manager reads from the running app: the agents on every
/// machine (from the sidebar), and a way to reach each machine's daemon.
/// Machines are named the way plugins name them, `LeoHostID.displayName`.
@MainActor final class LeoPluginAppSources: LeoPluginAgentSource, LeoPluginDaemonAccess {
    private let sidebar: LeoSidebarModel
    private let clients: any LeoMachineClientResolving
    private let spawnMemory: SpawnMachineMemory

    init(sidebar: LeoSidebarModel, clients: any LeoMachineClientResolving, spawnMemory: SpawnMachineMemory) {
        self.sidebar = sidebar
        self.clients = clients
        self.spawnMemory = spawnMemory
    }

    // MARK: LeoPluginAgentSource

    /// Every agent the sidebar shows. A row for an agent that moved away is a
    /// dormant record, not an agent on that machine, so it is left out.
    func currentAgents() -> [(LeoHostID, LeoAgent)] {
        sidebar.rows.filter { $0.movedTo == nil }.map { Self.agent(for: $0) }
    }

    /// The row's fields a plugin may see. The workspace path stays here.
    static func agent(for row: LeoAgentRow) -> (LeoHostID, LeoAgent) {
        (row.host, LeoAgent(name: row.name, template: row.template, repo: row.repo, branch: row.branch, status: row.status))
    }

    // MARK: LeoPluginDaemonAccess

    var machines: [String] { hosts.map(\.displayName) }

    var defaultMachine: String {
        LeoSpawnMachineDefault.resolve(context: nil, lastUsed: spawnMemory.lastUsed, statuses: sidebar.machineStatuses).displayName
    }

    func commands(forMachine name: String) -> (any LeoPluginAgentCommands)? {
        guard let host = hosts.first(where: { $0.displayName == name }), let daemon = clients.daemon(for: host) else { return nil }
        return LeoDaemonClientCommands(daemon)
    }

    /// The machine a plugin names, if the sidebar knows it.
    func host(forMachine name: String) -> LeoHostID? { hosts.first { $0.displayName == name } }

    private var hosts: [LeoHostID] { sidebar.machineOrder.isEmpty ? [.local] : sidebar.machineOrder }
}
