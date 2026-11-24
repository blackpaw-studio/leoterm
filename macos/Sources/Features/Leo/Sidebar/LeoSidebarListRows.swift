import LeoKit

/// B-413: what a machine's `Section` lists under its header, resolved once
/// for both the view and `LeoSidebarListRows`, so the row indices the
/// off-screen indicator mirrors can't drift from the rows the list draws.
enum LeoMachineListContent: Equatable {
    /// The offline card.
    case offline
    /// The "Loading agents…" note.
    case loading
    /// Folded to its header.
    case folded
    /// The "No agents" note.
    case noAgents
    /// A filter left the machine with nothing: no rows at all.
    case empty
    /// Each status group under a title row, then its agents.
    case groups

    /// The order is the view's: an offline machine shows its card even when
    /// the filter has text; loading shows its note; a folded one nothing.
    static func resolve(connectivity: LeoConnectivity, isFolded: Bool, hasGroups: Bool, isFiltering: Bool) -> Self {
        if connectivity.isOffline { return .offline }
        if connectivity == .loading { return .loading }
        if isFolded { return .folded }
        if hasGroups { return .groups }
        return isFiltering ? .empty : .noAgents
    }
}

/// B-413: the sidebar `List`'s table-row index of each agent row. Rows that
/// aren't drawn have no views to ask, so the indices are counted from the
/// same structure the view draws: the machine blocks, together, each one
/// header row then its content. They're counted from the first machine's
/// header; `LeoSidebarBlockLayout` adds the sections above them (B-438).
enum LeoSidebarListRows {
    /// A status group as listed: its title row, then (unless collapsed)
    /// each agent row with the dispatch rows under it.
    struct Group: Equatable {
        struct Agent: Equatable {
            let id: LeoAgentRow.ID
            let dispatchRows: Int
        }

        let isCollapsed: Bool
        let agents: [Agent]
    }

    struct Machine: Equatable {
        let content: LeoMachineListContent
        let groups: [Group]
    }

    struct Result: Equatable {
        /// Each listed agent row's index among the table's rows, in list order.
        let agentRows: [(id: LeoAgentRow.ID, tableRow: Int)]
        /// How many table rows the machine blocks occupy.
        let rowCount: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rowCount == rhs.rowCount && lhs.agentRows.elementsEqual(rhs.agentRows) { $0.id == $1.id && $0.tableRow == $1.tableRow }
        }
    }

    static func rows(of machines: [Machine]) -> Result {
        var next = 0
        var agentRows: [(id: LeoAgentRow.ID, tableRow: Int)] = []
        for machine in machines {
            next += 1 // The machine's header.
            switch machine.content {
            case .offline, .loading, .noAgents: next += 1
            case .folded, .empty: break
            case .groups:
                for group in machine.groups {
                    next += 1 // The group's title row.
                    guard !group.isCollapsed else { continue }
                    for agent in group.agents {
                        agentRows.append((agent.id, next))
                        next += 1 + agent.dispatchRows
                    }
                }
            }
        }
        return Result(agentRows: agentRows, rowCount: next)
    }
}
