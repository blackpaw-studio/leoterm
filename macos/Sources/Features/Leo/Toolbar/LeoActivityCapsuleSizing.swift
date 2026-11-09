import CoreGraphics

/// How wide the toolbar's activity capsule is, and what has to yield for it.
///
/// The capsule is centred in the toolbar region right of the sidebar, so
/// whatever sits to its left (the sidebar toggle and traffic lights while
/// the sidebar is collapsed, then the window title) is also taken from its
/// right. AppKit won't shrink a custom-view item to fit: one that doesn't
/// fit goes to the overflow chevron at its preferred width. So the width is
/// chosen from the room, and the rest gives way in order: the subtitle, the
/// update pill (ambient status, not "needs you"), then the title, before the
/// capsule shrinks to `minimumWidth` (a title stub, the glyph, the badge and
/// the bar). The trailing groups (view switch, Interrupt, "⋯") never give
/// way: their room is reserved at every width, so below the floor the
/// capsule stops shrinking and the window's own minimum size takes over.
enum LeoActivityCapsuleSizing {
    static let minimumWidth: CGFloat = 120
    /// The narrowest the capsule goes when there is no room to centre it: the
    /// glyph, a title stub, the badge and the bar. Its text truncates.
    static let compactWidth: CGFloat = 88
    /// The gap between an uncentred capsule and the trailing groups.
    static let capsuleGap: CGFloat = 8
    /// What the title with its subtitle, and the title alone, keep on each
    /// side of the centred capsule.
    static let subtitleSideReserve: CGFloat = 190
    static let titleSideReserve: CGFloat = 100
    /// What the trailing groups take right of the capsule at every width: the
    /// view switch (about 78 pt), Interrupt and "⋯" (one glass group, about
    /// 74 pt), the toolbar's gaps and trailing margin. Measured in the spike
    /// (see the plan's Step 0 findings).
    static let trailingGroupsReserve: CGFloat = 180
    /// What the capsule keeps on its far side while Chat sits beside the
    /// terminal: the trailing groups are over the chat pane then, so the
    /// column only needs a gap before the divider.
    static let sideBySideFarSideReserve: CGFloat = 56
    /// What the update pill takes right of the capsule when its real width
    /// can't be measured yet: its widest text, "Update Available: 0.00.0",
    /// is about 190 pt, plus the toolbar's spacing.
    static let updateFallbackReserve: CGFloat = 200
    /// The traffic lights and the sidebar toggle, from the window's left
    /// edge, while the sidebar is collapsed.
    static let collapsedSidebarChrome: CGFloat = 140

    struct Layout: Equatable {
        let width: CGFloat
        let showsSubtitle: Bool
        let showsTitle: Bool
        /// Whether the update pill has room; it gives way after the subtitle
        /// and before the title (an update is ambient status, not "needs you").
        let showsUpdateItem: Bool
        /// Whether the capsule sits centred in the region. With no room for
        /// that (the trailing groups' reserve is taken from both sides of a
        /// centred item) it sits left of the trailing groups instead, and
        /// never overflows into the toolbar's chevron.
        let isCentered: Bool
    }

    private struct Tier {
        let leftReserve: CGFloat
        let showsSubtitle: Bool
        let showsTitle: Bool
        let showsUpdateItem: Bool

        /// The room the tier keeps right of the capsule: the trailing
        /// groups, and the update pill's `pillReserve` while the tier shows it.
        func side(leadingChrome: CGFloat, pillReserve: CGFloat, farSideReserve: CGFloat) -> CGFloat {
            max(leadingChrome + leftReserve, farSideReserve + (showsUpdateItem ? pillReserve : 0))
        }
    }

    /// Richest first: the first tier whose capsule reaches `minimumWidth` wins.
    private static let tiers = [
        Tier(leftReserve: subtitleSideReserve, showsSubtitle: true, showsTitle: true, showsUpdateItem: true),
        Tier(leftReserve: titleSideReserve, showsSubtitle: false, showsTitle: true, showsUpdateItem: true),
        Tier(leftReserve: titleSideReserve, showsSubtitle: false, showsTitle: true, showsUpdateItem: false),
        Tier(leftReserve: 0, showsSubtitle: false, showsTitle: false, showsUpdateItem: false),
    ]

    /// `leadingChrome` is what sits left of the title inside the region
    /// (`collapsedSidebarChrome` or 0); `trailingReserve` is what sits right
    /// of the capsule beyond the trailing groups (`updateItemReserve` or 0).
    /// `farSideReserve` is what the trailing items keep right of the capsule
    /// (the trailing groups, unless Chat sits beside the terminal).
    /// `fixedReserve` is an item that never gives way (the reset-zoom
    /// button while a split is zoomed): added to `farSideReserve` at every tier.
    static func layout(
        availableToolbarWidth: CGFloat, leadingChrome: CGFloat, trailingReserve: CGFloat = 0,
        fixedReserve: CGFloat = 0, farSideReserve baseFarSideReserve: CGFloat = trailingGroupsReserve
    ) -> Layout {
        let farSideReserve = baseFarSideReserve + fixedReserve
        func width(_ tier: Tier) -> CGFloat {
            availableToolbarWidth - 2 * tier.side(leadingChrome: leadingChrome, pillReserve: trailingReserve, farSideReserve: farSideReserve)
        }
        guard let tier = tiers.first(where: { width($0) >= minimumWidth }) else {
            let room = availableToolbarWidth - leadingChrome - farSideReserve - capsuleGap
            return Layout(
                width: min(minimumWidth, max(compactWidth, room)), showsSubtitle: false, showsTitle: false,
                showsUpdateItem: false, isCentered: false)
        }
        return Layout(
            width: min(LeoActivityCapsulePresentation.maxWidth, width(tier)),
            showsSubtitle: tier.showsSubtitle, showsTitle: tier.showsTitle,
            showsUpdateItem: tier.showsUpdateItem, isCentered: true)
    }
}
