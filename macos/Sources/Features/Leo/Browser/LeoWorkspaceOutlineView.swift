import AppKit

/// The browser's outline with Finder's keys: → expands a folder (or steps
/// into an open one), ← collapses (or steps out to the parent), Return
/// activates the selected row, Escape hands focus back. Up and down stay
/// `NSOutlineView`'s own.
final class LeoWorkspaceOutlineView: NSOutlineView {
    var onActivate: () -> Void = {}
    var onEscape: () -> Void = {}
    /// What a drag to another app (Finder) may do, as last set.
    private(set) var outsideDragOperation: NSDragOperation = []

    private enum KeyCode {
        static let `return`: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case KeyCode.return, KeyCode.enter: onActivate()
        case KeyCode.escape: onEscape()
        case KeyCode.right: stepIn()
        case KeyCode.left: stepOut()
        default: super.keyDown(with: event)
        }
    }

    override func setDraggingSourceOperationMask(_ mask: NSDragOperation, forLocal isLocal: Bool) {
        super.setDraggingSourceOperationMask(mask, forLocal: isLocal)
        if !isLocal { outsideDragOperation = mask }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }

    private func stepIn() {
        let item = item(atRow: selectedRow)
        guard let item, isExpandable(item) else { return }
        guard isItemExpanded(item) else { return expandItem(item) }
        let first = selectedRow + 1
        guard first < numberOfRows, level(forRow: first) == level(forRow: selectedRow) + 1, let child = self.item(atRow: first),
              delegate?.outlineView?(self, shouldSelectItem: child) ?? true else { return }
        select(first)
    }

    private func stepOut() {
        guard let item = item(atRow: selectedRow) else { return }
        if isExpandable(item), isItemExpanded(item) { return collapseItem(item) }
        guard let parent = parent(forItem: item) else { return }
        select(row(forItem: parent))
    }

    private func select(_ row: Int) {
        guard row >= 0 else { return }
        selectRowIndexes([row], byExtendingSelection: false)
        scrollRowToVisible(row)
    }
}
