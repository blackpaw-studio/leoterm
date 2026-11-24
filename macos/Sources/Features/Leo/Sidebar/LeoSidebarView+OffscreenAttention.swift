import LeoKit

/// B-413: the sidebar list as the off-screen indicator sees it, counted from
/// the same `LeoMachineListContent` the machine sections draw.
extension LeoSidebarView {
    /// What each machine's section lists.
    func listMachines(_ machines: [LeoMachineSection]) -> [LeoSidebarListRows.Machine] {
        machines.map { machine in
            LeoSidebarListRows.Machine(
                content: listContent(of: machine),
                groups: machine.sections.map { section in
                    LeoSidebarListRows.Group(
                        isCollapsed: section.isCollapsed,
                        agents: section.rows.map { .init(id: $0.id, dispatchRows: model.visibleDispatchRows(for: $0).count) }
                    )
                }
            )
        }
    }

    func listContent(of machine: LeoMachineSection) -> LeoMachineListContent {
        .resolve(
            connectivity: machine.connectivity, isFolded: model.isMachineFolded(machine),
            hasGroups: !machine.sections.isEmpty, isFiltering: LeoSidebarLayout.isFiltering(model.query)
        )
    }

    /// The listed agent rows that need you, and how many table rows the
    /// list has down to the last machine block's. B-438: the sections above
    /// the agents push their rows down.
    func offscreenAttention(
        machines: [LeoMachineSection], layout: LeoSidebarBlockLayout
    ) -> (candidates: [LeoOffscreenAttention.Candidate], rowCount: Int) {
        let offset = layout.rowOffset(of: LeoSidebarSectionOrder.agents)
        let mirror = layout.agentRows
        let tableRows = Dictionary(mirror.agentRows.map { ($0.id, offset + $0.tableRow) }) { first, _ in first }
        let candidates = machines.flatMap(\.sections).filter { !$0.isCollapsed }.flatMap(\.rows).compactMap { row in
            let unreadCount = unread.count(for: row.id)
            guard let tableRow = tableRows[row.id],
                  let kind = LeoOffscreenAttention.kind(of: row, error: model.rowErrors[row.id], unread: unreadCount)
            else { return nil as LeoOffscreenAttention.Candidate? }
            return LeoOffscreenAttention.Candidate(
                id: row.id, name: row.displayName, tableRow: tableRow, kind: kind, unreadCount: unreadCount
            )
        }
        return (candidates, offset + mirror.rowCount)
    }
}
