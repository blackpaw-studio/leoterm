import AppKit

extension SplitTree {
    /// B-107: the pane upstream focuses once `node` closes, worked out
    /// from the tree before the close -- the same rule as
    /// `BaseTerminalController.removeSurfaceNode` (its private
    /// `findNextFocusTargetAfterClosing`). Closing the focused pane moves
    /// focus to the next pane when it was the leftmost, else to the
    /// previous one; closing any other pane leaves focus on `focused`.
    /// `nil` with nothing focused.
    func leoFocusAfterClosing(_ node: Node, focused: ViewType?) -> ViewType? {
        guard let focused else { return nil }
        guard node.contains(where: { $0 === focused }) else { return focused }
        guard let root else { return nil }
        let isLeftmost = root.leftmostLeaf() === node.leftmostLeaf()
        return focusTarget(for: isLeftmost ? .next : .previous, from: node)
    }
}
