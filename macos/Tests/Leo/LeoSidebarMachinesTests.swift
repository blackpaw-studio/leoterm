import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Leo Machines: one sidebar model holds a snapshot per machine. Agent
/// identity is (machine, name); one machine's snapshot, generation or
/// removal never touches another's rows, selection or errors.
@MainActor struct LeoSidebarMachinesTests {
    private let remote = LeoHostID.remote("dionysus")

    // MARK: Identity

    @Test func sameNamedAgentsOnTwoMachinesAreTwoRowsWithDistinctState() {
        let model = makeModel()
        let local = id("alfred", .local)
        let other = id("alfred", remote)

        model.selection = local
        model.setRowError("local boom", for: local)
        model.togglePin(other)

        #expect(model.rows.map(\.id) == [local, other])
        #expect(model.selection == local)
        #expect(model.rowErrors == [local: "local boom"])
        #expect(!model.isPinned(local))
        #expect(model.isPinned(other))
    }

    // MARK: Isolation

    @Test func anotherMachinesRefreshNeverClearsSelectionOrErrors() {
        let model = makeModel()
        let local = id("alfred", .local)
        model.selection = local
        model.setRowError("local boom", for: local)

        model.receive(snapshot([agent("alfred", remote)], generation: 2, refreshed: true), for: remote)

        #expect(model.selection == local)
        #expect(model.rowErrors == [local: "local boom"])
    }

    @Test func aMachinesRefreshClearsOnlyItsOwnErrors() {
        let model = makeModel()
        model.setRowError("local boom", for: id("alfred", .local))
        model.setRowError("remote boom", for: id("alfred", remote))

        model.receive(snapshot([agent("alfred", .local)], generation: 2, refreshed: true), for: .local)

        #expect(model.rowErrors == [id("alfred", remote): "remote boom"])
    }

    @Test func aMachineLosingTheSelectedAgentEndsOnlyItsOwnSelection() {
        let model = makeModel()
        model.selection = id("alfred", remote)

        model.receive(snapshot([], generation: 2), for: .local)
        #expect(model.selection == id("alfred", remote))

        model.receive(snapshot([], generation: 2), for: remote)
        #expect(model.selection == nil)
    }

    // MARK: Generations

    @Test func aLowerGenerationFromAnotherMachineIsAccepted() {
        let model = makeModel()
        model.receive(snapshot([agent("late", .local)], generation: 5), for: .local)
        model.receive(snapshot([agent("fresh", remote)], generation: 1), for: remote)

        #expect(model.snapshot(for: remote)?.rows.map(\.name) == ["fresh"])
        #expect(model.snapshot(for: .local)?.generation == 5)
    }

    @Test func aStaleGenerationOfTheSameMachineIsDropped() {
        let model = makeModel()
        model.receive(snapshot([agent("new", remote)], generation: 4), for: remote)
        model.receive(snapshot([agent("old", remote)], generation: 3), for: remote)

        #expect(model.snapshot(for: remote)?.rows.map(\.name) == ["new"])
    }

    // MARK: Removal

    @Test func removingAMachineDropsItsRowsStateAndLateSnapshots() {
        let model = makeModel()
        let other = id("alfred", remote)
        model.selection = other
        model.receiveStats(stats(cpu: 12), for: remote)

        model.setMachines([.local])

        #expect(model.rows.map(\.id) == [id("alfred", .local)])
        #expect(model.snapshot(for: remote) == nil)
        #expect(model.selection == nil)
        #expect(model.machineStats[remote] == nil)

        model.receive(snapshot([agent("ghost", remote)], generation: 9), for: remote)
        model.receiveStats(stats(cpu: 90), for: remote)
        #expect(model.snapshot(for: remote) == nil)
        #expect(model.machineStats[remote] == nil)
    }

    // MARK: Sections and collapse

    @Test func eachMachineHasItsOwnNeedsYouSectionInMachineOrder() {
        let model = makeModel()
        model.receive(snapshot([agent("a", .local, attention: .needsInput)], generation: 2), for: .local)
        model.receive(snapshot([agent("b", remote, attention: .needsInput)], generation: 2), for: remote)

        #expect(model.machineSections.map(\.host) == [.local, remote])
        for machine in model.machineSections {
            let needsYou = machine.sections.first { $0.id == LeoSidebarLayout.needsYouSectionID }
            #expect(needsYou?.rows.map(\.host) == [machine.host])
        }
    }

    @Test func collapseStateIsKeptPerMachine() {
        let model = makeModel()
        model.toggleCollapsed("running", host: remote)
        #expect(model.isCollapsed("running", host: remote))
        #expect(!model.isCollapsed("running", host: .local))

        model.toggleMachineCollapsed(.local)
        #expect(model.isMachineCollapsed(.local))
        #expect(!model.isMachineCollapsed(remote))
        #expect(model.machineSections.map(\.isCollapsed) == [true, false])
    }

    @Test func aCollapsedMachineHidesItsRowsFromTheVisibleList() {
        let model = makeModel()
        model.toggleMachineCollapsed(.local)

        #expect(model.visibleRows.map(\.host) == [remote])
        #expect(model.orderedRows.map(\.host) == [.local, remote])
    }

    @Test func machineOrderFollowsSetMachinesNotArrivalOrder() {
        let model = LeoSidebarModel()
        model.setMachines([.local, remote])
        model.receive(snapshot([agent("b", remote)], generation: 1), for: remote)
        model.receive(snapshot([agent("a", .local)], generation: 1), for: .local)

        #expect(model.rows.map(\.host) == [.local, remote])
    }

    // MARK: Per-machine facts

    @Test func connectivityFeaturesAndDispatchesAreReadPerMachine() {
        let model = makeModel()
        let node = LeoDispatchNode(dispatch: LeoDispatch(id: "d1", name: "n", status: "running", callerAgent: "alfred", attachable: true), depth: 0)
        model.receive(
            LeoSidebarSnapshot(
                rows: [agent("alfred", remote)], connectivity: .disconnected(reason: "tunnel exited", isRetrying: false), generation: 3,
                dispatchChildren: ["alfred": [node]], features: LeoDaemonFeatures(["agent_environments"])
            ),
            for: remote
        )

        #expect(model.isDisconnected(remote))
        #expect(!model.isDisconnected(.local))
        #expect(model.features(for: remote).contains(.agentEnvironments))
        #expect(!model.features(for: .local).contains(.agentEnvironments))
        #expect(model.dispatchChildren(for: agent("alfred", remote)).map(\.id) == ["d1"])
        #expect(model.dispatchChildren(for: agent("alfred", .local)).isEmpty)
    }

    @Test func attentionCountSumsAcrossMachinesAndNotifiesOnTheTotal() {
        let model = makeModel()
        var totals: [Int] = []
        model.attentionCountChanged = { totals.append($0) }

        model.receive(snapshot([agent("a", .local)], generation: 2, attention: 2), for: .local)
        model.receive(snapshot([agent("b", remote)], generation: 2, attention: 3), for: remote)
        model.receive(snapshot([agent("b", remote)], generation: 3, attention: 3), for: remote)

        #expect(model.attentionCount == 5)
        #expect(totals == [2, 5])
    }

    @Test func statsAreStoredPerMachine() {
        let model = makeModel()
        model.receiveStats(stats(cpu: 12), for: remote)
        #expect(model.machineStats[remote]?.cpuPercent == 12)
        #expect(model.machineStats[.local] == nil)
        #expect(model.machineSections.last?.stats?.cpuPercent == 12)

        model.receiveStats(nil, for: remote)
        #expect(model.machineStats[remote] == nil)
    }

    // MARK: Helpers

    /// This Mac and one remote, each with an agent named alfred.
    private func makeModel() -> LeoSidebarModel {
        let model = LeoSidebarModel()
        model.setMachines([.local, remote])
        model.receive(snapshot([agent("alfred", .local)], generation: 1), for: .local)
        model.receive(snapshot([agent("alfred", remote)], generation: 1), for: remote)
        return model
    }

    private func snapshot(
        _ rows: [LeoAgentRow], generation: Int, refreshed: Bool = false, attention: Int = 0
    ) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: .connected, generation: generation, listRefreshSucceeded: refreshed, attentionCount: attention
        )
    }

    private func agent(_ name: String, _ host: LeoHostID, attention: LeoAttentionBadge? = nil) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: nil, status: .running, activity: .idle, actionDetail: nil,
            attention: attention, startedAt: "s"
        )
    }

    private func id(_ name: String, _ host: LeoHostID) -> LeoAgentRow.ID { LeoAgentRow.ID(host: host, name: name) }

    private func stats(cpu: Double) -> LeoSidebarMachineStats {
        LeoSidebarMachineStats(
            sampledAt: Date(timeIntervalSince1970: 0), cpuPercent: cpu, memoryUsedBytes: 1, memoryTotalBytes: 2,
            diskUsedBytes: 1, diskTotalBytes: 2
        )
    }
}
