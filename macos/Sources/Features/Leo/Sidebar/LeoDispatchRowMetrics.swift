import SwiftUI

/// The vertical rhythm of a dispatch group in the sidebar list (B-275).
///
/// Measured on the real `LeoSidebarView` in a window before the change: an
/// agent row is its 51pt content plus a 4pt `List` inset above and below
/// (59pt), a 22pt dispatch row came out 32pt tall, the table's
/// `intercellSpacing` is 0 vertically, and rows have a 16pt leading and
/// trailing inset. The 32pt was the sidebar's default minimum row height:
/// neither `listRowInsets` nor `defaultMinListRowHeight` (on the row or the
/// List) nor a row-level `sidebarRowSize` moves it, and an 8pt `Color.clear`
/// row is stretched to 32 too. Only a List-level `sidebarRowSize = .small`
/// lowers it, to 24pt, for every non-header row; terminal rows are then
/// pinned back to their 32pt. So the List runs at `.small`, dispatch rows
/// sit at the 24pt floor, and the gap under a group is extra height on the
/// last row (the floor rules out a separate spacer row).
enum LeoDispatchRowMetrics {
    /// Fixed so every dispatch row is the same height whatever its content.
    static let rowHeight: CGFloat = 22
    /// The sidebar row size that lets a 24pt dispatch row stay 24pt.
    static let sidebarRowSize = SidebarRowSize.small
    /// A terminal row's height before the List dropped to `sidebarRowSize`,
    /// which they are pinned to.
    static let terminalRowHeight: CGFloat = 32
    /// Row to row distance within a group: the `sidebarRowSize` row's minimum
    /// height, which the 22pt row is centred in.
    static let pitch: CGFloat = 24
    /// The `listRowInsets` of a dispatch row: none. Explicit insets add to the
    /// cell's own 16pt side padding (measured: 16 here moved content 16pt
    /// right), and vertical ones didn't change a row's height at all.
    static let listRowInsets = EdgeInsets()
    /// The top and bottom `listRowInsets` of an agent row: none, down from the
    /// List's default 4pt. A one-line row is then its name line plus the
    /// row's own padding, 24pt, the `.small` estimate the list gives rows it
    /// hasn't drawn; at 32pt each such row grew when first drawn, after the
    /// list had clamped its scroll offset, and left the list short of its
    /// bottom.
    static let listVerticalInset: CGFloat = 0
    /// The `listRowInsets` of an agent row.
    static let agentRowInsets = EdgeInsets(top: listVerticalInset, leading: 0, bottom: listVerticalInset, trailing: 0)
    /// Extra height of a group's last dispatch row, below its content, so the
    /// group reads as one block apart from the next agent.
    static let groupGap: CGFloat = 16
    /// How much larger the last-dispatch to next-agent gap must be than any
    /// gap inside a group.
    static let minimumGroupContrast: CGFloat = 8

    /// The blank space around a 22pt row centred in its `pitch`.
    static var rowMargin: CGFloat { (pitch - rowHeight) / 2 }
    /// Blank space from an agent's line 2 down to its first dispatch's content.
    static var agentToFirstGap: CGFloat {
        LeoAgentRowMetrics.verticalPadding + listVerticalInset + rowMargin
    }
    /// Blank space between two dispatches' content.
    static var siblingGap: CGFloat { 2 * rowMargin }
    /// Blank space from a group's last dispatch to the next agent's content.
    static var groupToNextAgentGap: CGFloat {
        rowMargin + groupGap + listVerticalInset + LeoAgentRowMetrics.verticalPadding
    }
}
