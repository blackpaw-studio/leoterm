import Foundation

/// B-059: what the list shows and can select. `LeoSidebarView` draws from
/// the same predicates, so the keyboard moves and the list can't disagree.
extension LeoSidebarModel {
    /// The machine shows its header only: it is folded, or offline (a card
    /// says why). The filter shows every match, so it opens a folded one.
    func isMachineFolded(_ machine: LeoMachineSection) -> Bool {
        (machine.isCollapsed || machine.connectivity.isOffline) && !LeoSidebarLayout.isFiltering(query)
    }

    /// The Terminals section hides when the window has no shells, and
    /// while the filter (which searches agents) has text.
    func showsTerminals(hasTerminals: Bool) -> Bool {
        hasTerminals && !LeoSidebarLayout.isFiltering(query)
    }

    /// Every row the list can select, top to bottom: each machine's agents
    /// (an attachable dispatch right under its agent), then the window's
    /// terminals. Collapsed sections and folded, offline or still loading
    /// machines list nothing; a filter lists only its matches.
    func navigableItems(terminalIDs: [UUID]) -> [LeoSidebarItemID] {
        let agents = machineSections.flatMap { machine -> [LeoSidebarItemID] in
            guard machine.connectivity != .loading, !machine.connectivity.isOffline, !isMachineFolded(machine) else { return [] }
            return machine.sections.filter { !$0.isCollapsed }.flatMap(\.rows).flatMap { row in
                [LeoSidebarItemID.agent(row.id)] + selectableDispatches(under: row)
            }
        }
        let terminals = showsTerminals(hasTerminals: !terminalIDs.isEmpty) ? terminalIDs.map(LeoSidebarItemID.terminal) : []
        return agents + terminals
    }

    private func selectableDispatches(under row: LeoAgentRow) -> [LeoSidebarItemID] {
        visibleDispatchRows(for: row)
            .filter { isDispatchSelectable($0.node.dispatch, host: row.host) }
            .map { .dispatch(LeoDispatchRef(host: row.host, id: $0.id)) }
    }
}
