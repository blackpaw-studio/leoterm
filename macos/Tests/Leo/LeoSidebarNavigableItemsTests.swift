import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-059: the rows keyboard switching walks are the rows the sidebar list
/// shows and can select, in display order.
@MainActor struct LeoSidebarNavigableItemsTests {
    private let remote = LeoHostID.remote("box")

    @Test func listsAgentsInDisplayOrder() {
        let model = makeModel([.local: [agent("a"), agent("b")]])
        #expect(model.navigableItems(terminalIDs: []) == [id("a"), id("b")])
    }

    @Test func skipsRowsInCollapsedSections() {
        let model = makeModel([.local: [agent("run"), agent("off", status: .stopped)]])
        #expect(model.navigableItems(terminalIDs: []) == [id("run"), id("off")])

        model.toggleCollapsed("stopped", host: .local)
        #expect(model.navigableItems(terminalIDs: []) == [id("run")])
    }

    @Test func skipsFoldedMachine() {
        let model = makeModel([.local: [agent("a")], remote: [agent("b", host: remote)]])
        model.toggleMachineCollapsed(.local)
        #expect(model.navigableItems(terminalIDs: []) == [id("b", remote)])
    }

    @Test(arguments: [
        LeoConnectivity.loading, .failed(message: "refused"), .disconnected(reason: "tunnel exited", isRetrying: false),
    ])
    func skipsOfflineAndLoadingMachines(_ connectivity: LeoConnectivity) {
        let model = makeModel([.local: [agent("a")]])
        model.receive(
            LeoSidebarSnapshot(rows: [agent("b", host: remote)], connectivity: connectivity, generation: 2), for: remote
        )
        #expect(model.navigableItems(terminalIDs: []) == [id("a")])
    }

    @Test func filterListsOnlyMatchesAndHidesTerminals() {
        let model = makeModel([.local: [agent("alpha"), agent("beta", status: .stopped)]])
        model.toggleCollapsed("stopped", host: .local)
        model.query = "bet"
        let terminal = UUID()
        #expect(model.navigableItems(terminalIDs: [terminal]) == [id("beta")], "a filter opens collapsed sections")
    }

    @Test func attachableDispatchFollowsItsAgent_unattachableOmitted() {
        let model = makeModel(
            [.local: [agent("a"), agent("b")]],
            dispatches: ["a": [dispatch("d1", attachable: true), dispatch("d2", attachable: false)]]
        )
        #expect(model.navigableItems(terminalIDs: []) == [id("a"), .dispatch(ref("d1")), id("b")])
    }

    @Test func terminalsComeAfterMachines() {
        let model = makeModel([.local: [agent("a")], remote: [agent("b", host: remote)]])
        let first = UUID()
        let second = UUID()
        #expect(model.navigableItems(terminalIDs: [first, second]) == [id("a"), id("b", remote), .terminal(first), .terminal(second)])
    }

    // MARK: Helpers

    private func makeModel(
        _ hosts: [LeoHostID: [LeoAgentRow]], dispatches: [String: [LeoDispatch]] = [:]
    ) -> LeoSidebarModel {
        let model = LeoSidebarModel()
        model.setMachines(hosts.keys.sorted { $0 == .local || ($1 != .local && $0.displayName < $1.displayName) })
        for (host, rows) in hosts {
            model.receive(
                LeoSidebarSnapshot(
                    rows: rows, connectivity: .connected, generation: 1,
                    dispatchChildren: dispatches.mapValues { $0.map { LeoDispatchNode(dispatch: $0, depth: 0) } },
                    features: LeoDaemonFeatures(["dispatch_tree", "dispatch_attach"])
                ),
                for: host
            )
        }
        return model
    }

    private func agent(_ name: String, host: LeoHostID = .local, status: LeoAgentStatus = .running) -> LeoAgentRow {
        LeoAgentRow(host: host, name: name, template: nil, status: status, activity: .idle, actionDetail: nil, startedAt: "s")
    }

    private func dispatch(_ id: String, attachable: Bool) -> LeoDispatch {
        LeoDispatch(id: id, name: "n-\(id)", status: "running", callerAgent: "a", attachable: attachable)
    }

    private func id(_ name: String, _ host: LeoHostID = .local) -> LeoSidebarItemID {
        .agent(LeoAgentRow.ID(host: host, name: name))
    }

    private func ref(_ id: String) -> LeoDispatchRef { LeoDispatchRef(host: .local, id: id) }
}
