import Combine
import Foundation
import LeoKit

/// What the plugin manager reads from the running app: the agents on every
/// machine (from the sidebar), and a way to reach each machine's daemon.
/// Machines are named the way plugins name them, `LeoHostID.displayName`.
@MainActor final class LeoPluginAppSources: LeoPluginAgentSource, LeoPluginDaemonAccess {
    private let sidebar: LeoSidebarModel
    private let clients: any LeoMachineClientResolving
    private let spawnMemory: SpawnMachineMemory
    private var usageDiff = LeoPluginUsageDiff()
    private var usageSubscription: AnyCancellable?
    /// Told, after the sidebar rows have refreshed, which agents' usage changed.
    var onUsageChange: (LeoPluginAgentRef) -> Void = { _ in }

    init(sidebar: LeoSidebarModel, clients: any LeoMachineClientResolving, spawnMemory: SpawnMachineMemory) {
        self.sidebar = sidebar
        self.clients = clients
        self.spawnMemory = spawnMemory
        // Seeded with what the rows hold now, so launching is not a change for every agent.
        _ = usageDiff.changes(in: sidebar.rows)
        // `objectWillChange` fires before the rows change; the hop reads the refreshed rows,
        // so `agents.usage` never reads stale data after `usageChanged`.
        usageSubscription = sidebar.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.reportUsageChanges() } }
    }

    private func reportUsageChanges() {
        usageDiff.changes(in: sidebar.rows).forEach(onUsageChange)
    }

    // MARK: LeoPluginAgentSource

    /// Every agent the sidebar shows. A row for an agent that moved away is a
    /// dormant record, not an agent on that machine, so it is left out.
    func currentAgents() -> [(LeoHostID, LeoAgent)] {
        sidebar.rows.filter { $0.movedTo == nil }.map { Self.agent(for: $0) }
    }

    /// The row's fields. The snapshot layer withholds `workspace` and `model`
    /// from a plugin without `agents:usage`, so they are not gated here.
    static func agent(for row: LeoAgentRow) -> (LeoHostID, LeoAgent) {
        (row.host, LeoAgent(
            name: row.name, template: row.template, repo: row.repo, workspace: row.workspace, branch: row.branch,
            status: row.status, model: row.model))
    }

    /// This Mac's home directory, so a local workspace shows home-relative.
    var homeDirectory: String? { NSHomeDirectory() }

    /// What the app knows about one agent's usage; nil for an agent it doesn't show.
    func usage(for agent: LeoPluginAgentRef) -> LeoPluginUsageReading? {
        guard let row = sidebar.rows.first(where: { Self.ref(for: $0) == agent }) else { return nil }
        return Self.usageReading(for: row, daemonReportsUsage: sidebar.features(for: row.host).contains(.agentUsage))
    }

    /// A harness known never to report usage gets `{}` ("don't wait") rather than `null` ("not yet").
    /// A daemon without `agent_usage` reports nothing for any harness; an unknown harness may yet.
    nonisolated static func usageReading(for row: LeoAgentRow, daemonReportsUsage: Bool) -> LeoPluginUsageReading {
        let harnessReports = row.harness.map { reportingHarnesses.contains($0.lowercased()) } ?? true
        return LeoPluginUsageReading(
            configuredModel: row.model, usage: row.metadata?.usage, harnessReportsUsage: daemonReportsUsage && harnessReports)
    }

    nonisolated private static let reportingHarnesses: Set<String> = ["claude", "codex"]

    nonisolated fileprivate static func ref(for row: LeoAgentRow) -> LeoPluginAgentRef? {
        row.movedTo == nil ? LeoPluginAgentRef(machine: row.host.displayName, name: row.name) : nil
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

/// Which agents' usage moved between two looks at the sidebar rows, so
/// `usageChanged` fires once per real change. Tracks per machine and name;
/// an agent whose usage disappears counts as a change too.
struct LeoPluginUsageDiff {
    private var seen: [LeoPluginAgentRef: LeoAgentUsage] = [:]

    mutating func changes(in rows: [LeoAgentRow]) -> [LeoPluginAgentRef] {
        var next: [LeoPluginAgentRef: LeoAgentUsage] = [:]
        var changed: [LeoPluginAgentRef] = []
        for row in rows {
            guard let ref = LeoPluginAppSources.ref(for: row) else { continue }
            let usage = row.metadata?.usage
            if let usage { next[ref] = usage }
            if usage != seen[ref] { changed.append(ref) }
        }
        seen = next
        return changed
    }
}
