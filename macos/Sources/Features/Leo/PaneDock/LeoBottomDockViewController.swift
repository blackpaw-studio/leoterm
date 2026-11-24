import AppKit

/// The bottom dock (B-439): under the terminal and above the agent drawer,
/// as wide as the terminal column. Files' outline leads, the tab strip
/// trails; each column collapses while it has nothing to show, and the dock
/// as a whole collapses (`onOpenChange`) once neither does.
///
/// Like the other Leo splits, it implements none of the legacy
/// `NSSplitViewDelegate` sizing methods (they crash `NSSplitViewController`
/// at launch): thickness limits and holding priorities do the clamping.
final class LeoBottomDockViewController: NSSplitViewController {
    /// A nested split's holds act on the window split too: at or over the
    /// terminal column's own 250 (`LeoSidebarSplitMetrics.detailHoldingPriority`)
    /// they'd fight the right dock's for the column's width, and the column
    /// would end up at its minimum or the right dock at its. Under it, the
    /// window split alone sizes the column; in here the outline holds and
    /// the strip takes the column's changes.
    static let outlineHoldingPriority = NSLayoutConstraint.Priority(249)
    static let stripHoldingPriority = NSLayoutConstraint.Priority(248)

    let outlineItem: NSSplitViewItem?
    let stripItem: NSSplitViewItem?
    /// Whether a column shows, after each change.
    var onOpenChange: (Bool) -> Void = { _ in }

    init(outline: LeoDockSlotViewController?, strip: LeoDockSlotViewController?) {
        outlineItem = outline.map(Self.outlineItem(for:))
        stripItem = strip.map(Self.stripItem(for:))
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        [outlineItem, stripItem].compactMap { $0 }.forEach(addSplitViewItem)
    }

    required init?(coder: NSCoder) { nil }

    var isOpen: Bool { splitViewItems.contains { !$0.isCollapsed } }

    /// A column's slot asked to show or hide it.
    func setItem(_ item: NSSplitViewItem, collapsed: Bool) {
        if item.isCollapsed != collapsed { item.isCollapsed = collapsed }
        onOpenChange(isOpen)
    }

    private static func outlineItem(for slot: LeoDockSlotViewController) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: slot)
        // Drags stop at the minimum; only code collapses it (nothing to show).
        item.canCollapse = false
        item.isCollapsed = true
        item.holdingPriority = outlineHoldingPriority
        item.minimumThickness = LeoWorkspaceBrowserViewController.minimumWidth
        return item
    }

    private static func stripItem(for slot: LeoDockSlotViewController) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: slot)
        item.canCollapse = false
        item.isCollapsed = true
        item.holdingPriority = stripHoldingPriority
        item.minimumThickness = LeoPaneDockMetrics.minimumSize
        return item
    }
}

/// The terminal column's top (B-439): the terminal (or chat) over the bottom
/// dock. The dock keeps its height as the window resizes, opens at the
/// height the user last dragged it to (half the column the first time), and
/// a drag stops at `LeoPaneDockMetrics.minimumSize` instead of closing it.
final class LeoTerminalDockController: NSSplitViewController {
    let terminalItem: NSSplitViewItem
    let bottomItem: NSSplitViewItem
    let bottom: LeoBottomDockViewController
    /// The terminal and the overlay a dragged dock tab shows over it (B-440).
    let dropHost: LeoDockDropHostViewController
    private let store: LeoPaneDockStore
    /// A move we make ourselves, not the user's drag.
    private var isApplying = false
    /// The dock was shown before the view could size it.
    private var pendingOpening = false

    init(terminal: NSViewController, bottom: LeoBottomDockViewController, store: LeoPaneDockStore) {
        self.bottom = bottom
        self.store = store
        dropHost = LeoDockDropHostViewController(terminal: terminal)
        terminalItem = NSSplitViewItem(viewController: dropHost)
        terminalItem.holdingPriority = LeoAgentPaneSplitMetrics.terminalHoldingPriority
        terminalItem.minimumThickness = LeoSidebarSplitMetrics.minimumTerminalWidth
        bottomItem = NSSplitViewItem(viewController: bottom)
        bottomItem.holdingPriority = LeoSidebarSplitMetrics.editorHoldingPriority
        bottomItem.minimumThickness = LeoPaneDockMetrics.minimumSize
        bottomItem.canCollapse = false
        bottomItem.isCollapsed = true
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        addSplitViewItem(terminalItem)
        addSplitViewItem(bottomItem)
        bottom.onOpenChange = { [weak self] in self?.setBottomOpen($0) }
    }

    required init?(coder: NSCoder) { nil }

    var dropOverlay: LeoDockDropOverlay { dropHost.overlay }

    private var columnHeight: CGFloat { splitView.bounds.height }
    private var isReadyToPosition: Bool { view.window != nil && columnHeight > 0 }

    /// The bottom dock's height now (0 while it's closed).
    var bottomHeight: CGFloat { bottomItem.isCollapsed ? 0 : bottom.view.frame.height }

    func setBottomOpen(_ open: Bool) {
        guard bottomItem.isCollapsed == open else { return }
        // The layouts showing or hiding it aren't the user's height.
        isApplying = true
        bottomItem.isCollapsed = !open
        if open { openAtRememberedHeight() }
        DispatchQueue.main.async { [weak self] in self?.isApplying = false }
    }

    /// Gives the opened dock the height the user last left it at, or half
    /// the column, within its limits. Waits for a window and a height.
    private func openAtRememberedHeight() {
        guard isReadyToPosition else {
            pendingOpening = true
            return
        }
        pendingOpening = false
        isApplying = true
        view.layoutSubtreeIfNeeded()
        let available = columnHeight - splitView.dividerThickness
        let height = LeoPaneDockMetrics.clampedSize(store.size(of: .below) ?? (available / 2).rounded(.down), available: available)
        splitView.setPosition(
            LeoAgentPaneSplitMetrics.dividerPosition(paneHeight: height, columnHeight: columnHeight, dividerThickness: splitView.dividerThickness),
            ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in self?.isApplying = false }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard pendingOpening, isReadyToPosition else { return }
        pendingOpening = false
        // Outside this layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, !bottomItem.isCollapsed else { return }
            openAtRememberedHeight()
        }
    }

    /// Remembers the dock's height when the user moves its divider: not
    /// while we position it, and not on a layout (AppKit marks only divider
    /// moves; see `LeoSplitViewController.ResizeInfoKey`).
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard notification.userInfo?[LeoSplitViewController.ResizeInfoKey.userResize] != nil,
              !isApplying, !pendingOpening, isReadyToPosition, !bottomItem.isCollapsed, !view.inLiveResize else { return }
        let height = bottom.view.frame.height
        guard height >= LeoPaneDockMetrics.minimumSize - 0.5, abs(height - (store.size(of: .below) ?? -1)) > 0.5 else { return }
        store.setSize(height, of: .below)
    }
}
