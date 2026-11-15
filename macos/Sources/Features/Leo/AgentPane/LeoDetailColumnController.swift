import AppKit
import Combine

/// The detail column when plugins can contribute a pane: the terminal or chat
/// over the agent pane, in a vertical split. The pane's thickness is 30 pt
/// collapsed (min and max both), and between the drawer's minimum and half the
/// column expanded. With no agent or no tab the pane item is collapsed away.
///
/// Like `LeoSplitViewController`, it implements none of the legacy
/// `NSSplitViewDelegate` sizing methods, which opt the split view out of the
/// constraint-based layout `NSSplitViewController` requires (and crash the
/// app at launch): thickness limits and holding priorities do the clamping.
@MainActor final class LeoDetailColumnController: NSSplitViewController {
    let terminalItem: NSSplitViewItem
    let paneItem: NSSplitViewItem
    private let model: LeoAgentPaneModel
    private var subscription: AnyCancellable?
    /// The pane height last put in place by us (not the user's drag), and
    /// whether a requested position is still waiting for the view to be in a window.
    private var appliedHeight: CGFloat?
    private var isApplying = false
    /// The column height at the last divider notification: a change means the window moved the divider.
    private var lastColumnHeight: CGFloat?

    init(detail: NSViewController, model: LeoAgentPaneModel) {
        self.model = model
        terminalItem = NSSplitViewItem(viewController: detail)
        terminalItem.holdingPriority = LeoAgentPaneSplitMetrics.terminalHoldingPriority
        paneItem = NSSplitViewItem(viewController: LeoAgentPaneViewController(model: model))
        paneItem.holdingPriority = LeoAgentPaneSplitMetrics.paneHoldingPriority
        // A drag below the minimum must never collapse the pane (tab bar included);
        // `isCollapsed` set from code still hides it when there is nothing to show.
        paneItem.canCollapse = false
        paneItem.isCollapsed = true
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        addSplitViewItem(terminalItem)
        addSplitViewItem(paneItem)
        subscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyModel() }
    }

    required init?(coder: NSCoder) { nil }

    private var columnHeight: CGFloat { splitView.bounds.height }
    private var isReadyToPosition: Bool { view.window != nil && columnHeight > 0 }

    // MARK: Applying the model

    private func applyModel() {
        let shown = model.isShown
        if paneItem.isCollapsed == shown { paneItem.isCollapsed = !shown }
        applyLimits()
        positionDivider()
    }

    private func applyLimits() {
        let limits = LeoAgentPaneSplitMetrics.limits(isExpanded: model.isExpanded, columnHeight: columnHeight)
        paneItem.minimumThickness = limits.min
        paneItem.maximumThickness = limits.max
    }

    /// Puts the pane at its collapsed or remembered height. Until the view is
    /// in a window, `setPosition` is silently dropped, so it waits for `viewDidLayout`.
    private func positionDivider() {
        guard model.isShown, isReadyToPosition else { return }
        let wanted = model.isExpanded ? model.state.displayedHeight(columnHeight: columnHeight) : LeoAgentPaneState.collapsedHeight
        guard abs((appliedHeight ?? -1) - wanted) > 0.5 else { return }
        isApplying = true
        // Loosen the limits for the move, then restore them.
        paneItem.minimumThickness = 0
        paneItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        splitView.setPosition(
            LeoAgentPaneSplitMetrics.dividerPosition(
                paneHeight: wanted, columnHeight: columnHeight, dividerThickness: splitView.dividerThickness),
            ofDividerAt: 0)
        applyLimits()
        appliedHeight = wanted
        DispatchQueue.main.async { [weak self] in self?.isApplying = false }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyLimits()
        positionDivider()
    }

    // MARK: The user's drag

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let columnHeight = columnHeight
        defer { lastColumnHeight = columnHeight }
        guard !isApplying, model.isExpanded, isReadyToPosition, !paneItem.isCollapsed else { return }
        let height = paneItem.viewController.view.frame.height
        guard LeoAgentPaneSplitMetrics.shouldPersistHeight(
            height: height, appliedHeight: appliedHeight, columnHeight: columnHeight,
            previousColumnHeight: lastColumnHeight, isLiveResize: view.inLiveResize)
        else { return }
        appliedHeight = height
        model.setHeight(height, columnHeight: columnHeight)
    }
}
