import CoreGraphics

extension LeoActivityCapsuleSizing {
    /// The least gap between the capsule and the chat pane beside the terminal.
    static let chatClearance: CGFloat = 12

    /// Where the capsule sits in the window, and how wide.
    struct Placement: Equatable {
        let layout: Layout
        /// The capsule's leading edge, in window coordinates.
        let minX: CGFloat
        /// What the capsule's container adds to its right, so that AppKit's
        /// centring of the container leaves the capsule at `minX`.
        let trailingPad: CGFloat

        var width: CGFloat { layout.width }
        var maxX: CGFloat { minX + layout.width }
    }

    /// The capsule for a window `windowWidth` wide whose sidebar takes
    /// `sidebarWidth`. `chatLeadingEdge` is the chat pane's leading edge in
    /// window coordinates when Chat is beside the terminal, else nil.
    ///
    /// Beside Chat the terminal column is the capsule's room: it gets the
    /// width and variant the column leaves, as if the column were the whole
    /// toolbar region, and is centred on it. That keeps it clear of the chat
    /// pane by at least `chatClearance` (the "⋯" item's reserve on the
    /// column's far side is the larger gap).
    static func placement(windowWidth: CGFloat, sidebarWidth: CGFloat, chatLeadingEdge: CGFloat?, leadingChrome: CGFloat, trailingReserve: CGFloat = 0
    ) -> Placement {
        let regionWidth = windowWidth - sidebarWidth
        let regionCentre = sidebarWidth + regionWidth / 2
        guard let chatLeadingEdge else {
            let layout = layout(availableToolbarWidth: regionWidth, leadingChrome: leadingChrome, trailingReserve: trailingReserve)
            return Placement(layout: layout, minX: regionCentre - layout.width / 2, trailingPad: 0)
        }
        let terminalWidth = chatLeadingEdge - LeoChatLayout.dividerWidth - sidebarWidth
        let terminalCentre = sidebarWidth + terminalWidth / 2
        let layout = layout(availableToolbarWidth: terminalWidth, leadingChrome: leadingChrome)
        return Placement(
            layout: layout, minX: terminalCentre - layout.width / 2, trailingPad: max(0, 2 * (regionCentre - terminalCentre)))
    }
}
