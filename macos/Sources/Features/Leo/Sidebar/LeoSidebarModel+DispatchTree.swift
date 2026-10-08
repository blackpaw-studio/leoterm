import Foundation

/// One dispatch row as the sidebar draws it: the node, and whether it has
/// children to disclose (and has them collapsed).
struct LeoDispatchRowItem: Equatable, Identifiable {
    let node: LeoDispatchNode
    let hasChildren: Bool
    let isCollapsed: Bool

    var id: String { node.id }
}

/// B-266: a dispatch with children shows a disclosure control; collapse
/// state is kept per dispatch id for as long as it lives.
extension LeoSidebarModel {
    /// `row`'s dispatches with the children of every collapsed one left
    /// out. The nodes are depth first, so a node has children when the
    /// next one is deeper, and a collapsed node hides every deeper node
    /// after it up to the next one at its own depth or shallower.
    func visibleDispatchRows(for row: LeoAgentRow) -> [LeoDispatchRowItem] {
        let nodes = dispatchChildren(for: row)
        var hiddenBelow: Int?
        var items: [LeoDispatchRowItem] = []
        for (index, node) in nodes.enumerated() {
            if let depth = hiddenBelow {
                guard node.depth <= depth else { continue }
                hiddenBelow = nil
            }
            let hasChildren = index + 1 < nodes.count && nodes[index + 1].depth > node.depth
            let isCollapsed = hasChildren && collapsedDispatches.contains(LeoDispatchRef(host: row.host, id: node.id))
            items.append(LeoDispatchRowItem(node: node, hasChildren: hasChildren, isCollapsed: isCollapsed))
            if isCollapsed { hiddenBelow = node.depth }
        }
        return items
    }

    func toggleDispatchCollapsed(_ ref: LeoDispatchRef) {
        if collapsedDispatches.remove(ref) == nil { collapsedDispatches.insert(ref) }
    }

    /// Forgets collapse state for dispatches that are gone.
    func pruneCollapsedDispatches() {
        guard !collapsedDispatches.isEmpty else { return }
        let present = Set(snapshot.rows.flatMap { row in
            dispatchChildren(for: row).map { LeoDispatchRef(host: row.host, id: $0.id) }
        })
        let kept = collapsedDispatches.intersection(present)
        if kept != collapsedDispatches { collapsedDispatches = kept }
    }
}
