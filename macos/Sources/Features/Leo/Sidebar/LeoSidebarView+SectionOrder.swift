import LeoKit
import SwiftUI

/// B-438: the list's top-level sections in the saved order, with the table
/// rows each takes, so a row index counted inside one section (an agent's,
/// for the off-screen indicator; the Terminals rows, for their closing)
/// becomes an index in the list.
struct LeoSidebarBlockLayout {
    let blocks: [LeoSidebarTopLevel.Block]
    /// The shown sections, top to bottom.
    let sections: [String]
    /// Each shown section's table rows: its header and what it lists.
    let rowCounts: [String: Int]
    /// The agents' rows, counted from the Agents section's first row.
    let agentRows: LeoSidebarListRows.Result

    func rowOffset(of key: String) -> Int {
        LeoSidebarTopLevel.rowOffset(of: key, in: sections, rowCounts: rowCounts)
    }
}

extension LeoSidebarView {
    func blockLayout(machines: [LeoMachineSection], pluginRows: [String: Int]) -> LeoSidebarBlockLayout {
        let blocks = LeoSidebarTopLevel.blocks(
            machines: machines.map(\.host), showsTerminals: showsTerminals,
            pluginSectionIDs: shownPluginEntries.map(\.id), order: model.preferences.sectionOrder
        )
        let agentRows = LeoSidebarListRows.rows(of: listMachines(machines))
        let builtIns = [
            LeoSidebarSectionOrder.agents: agentRows.rowCount,
            // Its header's row and each terminal row `LeoTerminalsSection` lists.
            LeoSidebarSectionOrder.terminals: showsTerminals ? terminals.list.labels.count + 1 : 0,
        ]
        return LeoSidebarBlockLayout(
            blocks: blocks, sections: LeoSidebarTopLevel.sectionKeys(of: blocks),
            rowCounts: builtIns.merging(pluginRows) { builtIn, _ in builtIn }, agentRows: agentRows
        )
    }

    /// Each listed plugin section's table rows, by section key, from the
    /// plugins' content as it is now.
    func pluginSectionRowCounts() -> [String: Int] {
        guard let sections = model.pluginSections else { return [:] }
        let counts = shownPluginEntries.map { entry in
            let content = sections.isExpanded(entry) ? pluginSurfaces?.content(for: entry.slotKey) : nil
            return (LeoSidebarSectionOrder.pluginKey(entry.id), LeoPluginSidebarSection.tableRows(listing: content))
        }
        return Dictionary(counts) { first, _ in first }
    }

    /// What `key`'s header does to move its section.
    func sectionMover(_ key: String, in layout: LeoSidebarBlockLayout) -> LeoSidebarSectionMover {
        let visible = layout.sections
        return LeoSidebarSectionMover(
            key: key, visible: visible, drags: model.sectionDrags,
            move: { [model] in model.moveSection(key, $0, visible: visible) },
            drop: { [model] in model.moveSection($0, onto: key, visible: visible) }
        )
    }
}

/// Re-renders the sidebar when a listed plugin section's row count changes
/// (B-438). The sidebar doesn't observe the plugins' content (each section
/// does), but every section below one moves with its rows.
struct LeoPluginSectionRowsWatcher: View {
    @ObservedObject var surfaces: LeoPluginSurfaces
    let counts: () -> [String: Int]
    let changed: ([String: Int]) -> Void

    var body: some View {
        let current = counts()
        Color.clear
            .onAppear { changed(current) }
            .onChange(of: current) { changed($0) }
    }
}
