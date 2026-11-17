import Testing

@testable import Ghostty
@testable import LeoKit

/// B-413: the table-row index of each agent row, mirrored from the list's
/// structure.
struct LeoSidebarListRowsTests {
    typealias Group = LeoSidebarListRows.Group
    typealias Machine = LeoSidebarListRows.Machine

    private func id(_ name: String) -> LeoAgentID { LeoAgentID(host: .local, name: name) }

    private func group(_ names: [String], dispatches: [String: Int] = [:], collapsed: Bool = false) -> Group {
        Group(isCollapsed: collapsed, agents: names.map { .init(id: id($0), dispatchRows: dispatches[$0] ?? 0) })
    }

    private func indices(_ machines: [Machine]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: LeoSidebarListRows.rows(of: machines).agentRows.map { ($0.id.name, $0.tableRow) })
    }

    @Test func agentsFollowTheMachineHeaderAndEachGroupTitle() {
        let machine = Machine(content: .groups, groups: [group(["a", "b"]), group(["c"])])
        // 0 header, 1 title, 2 a, 3 b, 4 title, 5 c
        #expect(indices([machine]) == ["a": 2, "b": 3, "c": 5])
        #expect(LeoSidebarListRows.rows(of: [machine]).rowCount == 6)
    }

    @Test func dispatchRowsPushLaterAgentsDown() {
        let machine = Machine(content: .groups, groups: [group(["a", "b"], dispatches: ["a": 3])])
        #expect(indices([machine]) == ["a": 2, "b": 6])
    }

    @Test func aCollapsedGroupKeepsItsTitleAndLosesItsRows() {
        let machine = Machine(content: .groups, groups: [group(["a"], collapsed: true), group(["b"])])
        // 0 header, 1 title, 2 title, 3 b
        #expect(indices([machine]) == ["b": 3])
    }

    @Test(arguments: [
        (LeoMachineListContent.offline, 2), (.loading, 2), (.noAgents, 2), (.folded, 1), (.empty, 1),
    ])
    func machineWithoutGroupsTakesItsHeaderAndItsNote(_ content: LeoMachineListContent, _ rows: Int) {
        let result = LeoSidebarListRows.rows(of: [Machine(content: content, groups: [group(["hidden"])])])
        #expect(result.rowCount == rows)
        #expect(result.agentRows.isEmpty, "a machine showing no groups lists no agents")
    }

    @Test func aSecondMachineStartsAfterTheFirst() {
        let first = Machine(content: .groups, groups: [group(["a"])]) // 0 header, 1 title, 2 a
        let offline = Machine(content: .offline, groups: [])          // 3 header, 4 card
        let second = Machine(content: .groups, groups: [group(["z"])]) // 5 header, 6 title, 7 z
        #expect(indices([first, offline, second]) == ["a": 2, "z": 7])
    }

    @Test(arguments: [
        (LeoConnectivity.failed(message: "x"), false, false, false, LeoMachineListContent.offline),
        (.disconnected(reason: "x", isRetrying: false), true, true, false, .offline),
        (.loading, false, true, false, .loading),
        (.connected, true, true, false, .folded),
        (.connected, false, true, false, .groups),
        (.connected, false, false, false, .noAgents),
        (.connected, false, false, true, .empty),
    ])
    func contentFollowsTheViewsOrder(
        _ connectivity: LeoConnectivity, _ isFolded: Bool, _ hasGroups: Bool, _ isFiltering: Bool, _ expected: LeoMachineListContent
    ) {
        #expect(LeoMachineListContent.resolve(connectivity: connectivity, isFolded: isFolded, hasGroups: hasGroups, isFiltering: isFiltering) == expected)
    }
}
