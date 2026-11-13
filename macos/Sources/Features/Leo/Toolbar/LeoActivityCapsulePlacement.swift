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
        // The pill is not in the column: it sits with the trailing groups, over the chat pane.
        let columnLayout = layout(
            availableToolbarWidth: terminalWidth, leadingChrome: leadingChrome, trailingReserve: 0,
            fixedReserve: fixedReserve, farSideReserve: sideBySideFarSideReserve)
        let trailingPad = max(0, 2 * (regionCentre - terminalCentre))
        // The container's padded right edge reaches under the trailing groups:
        // clear of the switch and "⋯" (they never fold), and the toggles and
        // Interrupt fold while it reaches them.
        let fitted = clearingTrailingGroups(
            columnLayout, centre: terminalCentre, trailingPad: trailingPad, windowWidth: windowWidth, fixedReserve: fixedReserve,
            pillReserve: trailingReserve)
        let columnPlacement = Placement(layout: fitted, minX: terminalCentre - fitted.width / 2, trailingPad: trailingPad)
        let keepsEverything = fitted.showsToggles && fitted.showsInterrupt && (trailingReserve == 0 || fitted.showsUpdateItem)
        if keepsEverything { return columnPlacement }
        return flowing(
            windowWidth: windowWidth, sidebarWidth: sidebarWidth, chatLeadingEdge: chatLeadingEdge, leadingChrome: leadingChrome,
            pillReserve: trailingReserve, fixedReserve: fixedReserve) ?? columnPlacement
    }

    /// The capsule between the title and the trailing groups, with all of them
    /// shown, when the room allows. The trailing items sit over the chat pane,
    /// but the padded container that centres the capsule on the terminal
    /// column reaches as far right as the capsule plus the chat pane's width,
    /// so the toggles and Interrupt cannot fit beside it (the container would
    /// cover them); the capsule is not centred then, and AppKit's flexible
    /// spaces put it midway between the title and the pill or toggles. The
    /// title keeps its subtitle's room, so the capsule sits as far left as it
    /// can, and the pill gives way before the capsule shrinks below its floor.
    private static func flowing(
        windowWidth: CGFloat, sidebarWidth: CGFloat, chatLeadingEdge: CGFloat, leadingChrome: CGFloat, pillReserve: CGFloat,
        fixedReserve: CGFloat
    ) -> Placement? {
        let titleWidth = subtitleSideReserve - titleGap
        for pill in pillReserve > 0 ? [pillReserve, 0] : [0] {
            let trailing = trailingGroupsReserve + fixedReserve + pill
            let titleEnd = sidebarWidth + leadingChrome + titleWidth
            let trailingStart = windowWidth - trailing
            let centre = (titleEnd + trailingStart) / 2
            let room = min(
                trailingStart - titleEnd - 2 * titleGap, 2 * (chatLeadingEdge - chatClearance - centre),
                LeoActivityCapsulePresentation.maxWidth)
            guard room >= minimumWidth else { continue }
            let layout = Layout(
                width: room, showsSubtitle: true, showsTitle: true, showsUpdateItem: pill > 0, isCentered: false,
                showsToggles: true, showsInterrupt: true, titleWidth: titleWidth)
            return Placement(layout: layout, minX: centre - room / 2, trailingPad: 0)
        }
        return nil
    }

    /// `layout` narrowed, if it has to be, so its container (the capsule plus
    /// `trailingPad`, centred on `centre`) ends `trailingReserveMinimal` short
    /// of the window's edge; and which trailing items the room that is left
    /// right of the container still holds. An item that does not fit there
    /// must be hidden: AppKit would fold it into the overflow, and its
    /// chevron takes room the centred container then lacks (it folds too).
    /// `pillReserve` is the update pill's room (0: no pill showing).
    private static func clearingTrailingGroups(
        _ layout: Layout, centre: CGFloat, trailingPad: CGFloat, windowWidth: CGFloat, fixedReserve: CGFloat,
        pillReserve: CGFloat
    ) -> Layout {
        func room(_ width: CGFloat) -> CGFloat { windowWidth - (centre - width / 2 + width + trailingPad) }
        let minimal = trailingReserveMinimal + fixedReserve
        var width = layout.width
        if room(width) < minimal { width = max(compactWidth, width - 2 * (minimal - room(width))) }
        let space = room(width)
        return Layout(
            width: width, showsSubtitle: layout.showsSubtitle, showsTitle: layout.showsTitle,
            // The pill gives way before the toggles, as everywhere else: it needs the room for all of them too.
            showsUpdateItem: pillReserve > 0 && space >= trailingGroupsReserve + fixedReserve + pillReserve,
            isCentered: layout.isCentered,
            showsToggles: space >= trailingGroupsReserve + fixedReserve,
            showsInterrupt: space >= trailingReserveWithoutToggles + fixedReserve, titleWidth: layout.titleWidth)
    }
}
