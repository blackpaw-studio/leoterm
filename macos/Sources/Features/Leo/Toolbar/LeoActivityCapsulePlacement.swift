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
    /// pane by at least `chatClearance` (`sideBySideFarSideReserve` on the
    /// column's far side is the larger gap; the trailing groups are over the chat pane).
    static func placement(
        windowWidth: CGFloat, sidebarWidth: CGFloat, chatLeadingEdge: CGFloat?, leadingChrome: CGFloat,
        trailingReserve: CGFloat = 0, fixedReserve: CGFloat = 0
    ) -> Placement {
        let regionWidth = windowWidth - sidebarWidth
        let regionCentre = sidebarWidth + regionWidth / 2
        guard let chatLeadingEdge else {
            let layout = layout(
                availableToolbarWidth: regionWidth, leadingChrome: leadingChrome, trailingReserve: trailingReserve,
                fixedReserve: fixedReserve)
            return Placement(layout: layout, minX: regionCentre - layout.width / 2, trailingPad: 0)
        }
        let terminalWidth = chatLeadingEdge - LeoChatLayout.dividerWidth - sidebarWidth
        let terminalCentre = sidebarWidth + terminalWidth / 2
        let columnLayout = layout(
            availableToolbarWidth: terminalWidth, leadingChrome: leadingChrome, trailingReserve: trailingReserve,
            fixedReserve: fixedReserve, farSideReserve: sideBySideFarSideReserve)
        let trailingPad = max(0, 2 * (regionCentre - terminalCentre))
        // The container's padded right edge reaches under the trailing groups:
        // clear of the switch and "⋯" (they never fold), and the toggles and
        // Interrupt fold while it reaches them.
        let fitted = clearingTrailingGroups(
            columnLayout, centre: terminalCentre, trailingPad: trailingPad, windowWidth: windowWidth, fixedReserve: fixedReserve)
        return Placement(layout: fitted, minX: terminalCentre - fitted.width / 2, trailingPad: trailingPad)
    }

    /// `layout` narrowed, if it has to be, so its container (the capsule plus
    /// `trailingPad`, centred on `centre`) ends `trailingReserveMinimal` short
    /// of the window's edge; and which trailing items the room that is left
    /// right of the container still holds.
    private static func clearingTrailingGroups(
        _ layout: Layout, centre: CGFloat, trailingPad: CGFloat, windowWidth: CGFloat, fixedReserve: CGFloat
    ) -> Layout {
        func room(_ width: CGFloat) -> CGFloat { windowWidth - (centre - width / 2 + width + trailingPad) }
        let minimal = trailingReserveMinimal + fixedReserve
        var width = layout.width
        if room(width) < minimal { width = max(compactWidth, width - 2 * (minimal - room(width))) }
        let space = room(width)
        return Layout(
            width: width, showsSubtitle: layout.showsSubtitle, showsTitle: layout.showsTitle,
            showsUpdateItem: layout.showsUpdateItem, isCentered: layout.isCentered,
            showsToggles: space >= trailingGroupsReserve + fixedReserve,
            showsInterrupt: space >= trailingReserveWithoutToggles + fixedReserve)
    }
}
