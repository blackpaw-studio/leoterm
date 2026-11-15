import AppKit

/// The numbers the nested terminal-over-pane split is built from. Both
/// holding priorities stay in NSSplitView's low band (250-260): a priority
/// of 750 freezes a pane at its minimum thickness. Only their order matters:
/// the pane is higher, so it keeps its height when the window resizes and the
/// terminal absorbs the change.
enum LeoAgentPaneSplitMetrics {
    static let terminalHoldingPriority = NSLayoutConstraint.Priority(250)
    static let paneHoldingPriority = NSLayoutConstraint.Priority(260)

    /// The pane item's thickness limits. Collapsed, min and max are both the
    /// tab bar's height. Expanded, they are the drawer's minimum and half the
    /// column (never below the minimum, so the limits can't invert).
    static func limits(isExpanded: Bool, columnHeight: CGFloat) -> (min: CGFloat, max: CGFloat) {
        guard isExpanded else { return (LeoAgentPaneState.collapsedHeight, LeoAgentPaneState.collapsedHeight) }
        return (LeoAgentPaneState.minHeight, LeoAgentPaneState.maxHeight(columnHeight: columnHeight))
    }

    /// Where the divider sits (from the top of a stacked split view) to give
    /// the pane `paneHeight`.
    static func dividerPosition(paneHeight: CGFloat, columnHeight: CGFloat, dividerThickness: CGFloat) -> CGFloat {
        columnHeight - paneHeight - dividerThickness
    }

    /// The inverse: the pane's height for a divider position.
    static func paneHeight(dividerPosition: CGFloat, columnHeight: CGFloat, dividerThickness: CGFloat) -> CGFloat {
        columnHeight - dividerPosition - dividerThickness
    }

    /// Whether a divider move is the user's drag, and so worth remembering.
    /// A window resize moves the divider too (the 0.5x max clamp on a shrink),
    /// and persisting that would overwrite the height the user chose: the column
    /// height changing or a live resize in progress both mean the window did it.
    static func shouldPersistHeight(
        height: CGFloat, appliedHeight: CGFloat?, columnHeight: CGFloat,
        previousColumnHeight: CGFloat?, isLiveResize: Bool
    ) -> Bool {
        guard !isLiveResize, height >= LeoAgentPaneState.minHeight else { return false }
        if let previousColumnHeight, abs(columnHeight - previousColumnHeight) > 0.5 { return false }
        return abs(height - (appliedHeight ?? height)) > 0.5
    }
}
