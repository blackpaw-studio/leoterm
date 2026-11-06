import CoreGraphics

/// How wide the toolbar's activity capsule is, and what has to yield for it.
///
/// The capsule is centred in the toolbar region right of the sidebar, so
/// whatever sits to its left (the sidebar toggle and traffic lights while
/// the sidebar is collapsed, then the window title) is also taken from its
/// right. AppKit won't shrink a custom-view item to fit: one that doesn't
/// fit goes to the overflow chevron at its preferred width. So the width is
/// chosen from the room, and the rest gives way in order: the subtitle, the
/// update pill (ambient status, not "needs you"), the title, then the "⋯" item, before the capsule drops below `minimumWidth`
/// (a title stub, the glyph, the badge and the bar).
enum LeoActivityCapsuleSizing {
    static let minimumWidth: CGFloat = 120
    /// What the title with its subtitle, the title alone, and the "⋯" item
    /// (alone, then not at all) keep on each side of the centred capsule.
    static let subtitleSideReserve: CGFloat = 190
    static let titleSideReserve: CGFloat = 100
    static let moreSideReserve: CGFloat = 56
    static let bareSideReserve: CGFloat = 16
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
        let showsMoreItem: Bool
        /// Whether the update pill has room; it gives way after the subtitle
        /// and before the title (an update is ambient status, not "needs you").
        let showsUpdateItem: Bool
    }

    private struct Tier {
        let leftReserve: CGFloat
        let rightReserve: CGFloat
        let showsSubtitle: Bool
        let showsTitle: Bool
        let showsMoreItem: Bool
        let showsUpdateItem: Bool

        /// The room the tier keeps right of the capsule: its items, and the
        /// update pill's `pillReserve` while the tier shows it.
        func side(leadingChrome: CGFloat, pillReserve: CGFloat) -> CGFloat {
            max(leadingChrome + leftReserve, rightReserve + (showsUpdateItem ? pillReserve : 0))
        }
    }

    /// Richest first: the first tier whose capsule reaches `minimumWidth` wins.
    private static let tiers = [
        Tier(leftReserve: subtitleSideReserve, rightReserve: moreSideReserve, showsSubtitle: true, showsTitle: true, showsMoreItem: true, showsUpdateItem: true),
        Tier(leftReserve: titleSideReserve, rightReserve: moreSideReserve, showsSubtitle: false, showsTitle: true, showsMoreItem: true, showsUpdateItem: true),
        Tier(leftReserve: titleSideReserve, rightReserve: moreSideReserve, showsSubtitle: false, showsTitle: true, showsMoreItem: true, showsUpdateItem: false),
        Tier(leftReserve: 0, rightReserve: moreSideReserve, showsSubtitle: false, showsTitle: false, showsMoreItem: true, showsUpdateItem: false),
        Tier(leftReserve: 0, rightReserve: bareSideReserve, showsSubtitle: false, showsTitle: false, showsMoreItem: false, showsUpdateItem: false),
    ]

    /// `leadingChrome` is what sits left of the title inside the region
    /// (`collapsedSidebarChrome` or 0); `trailingReserve` is what sits right
    /// of the capsule beyond the "⋯" item (`updateItemReserve` or 0).
    static func layout(availableToolbarWidth: CGFloat, leadingChrome: CGFloat, trailingReserve: CGFloat = 0) -> Layout {
        func width(_ tier: Tier) -> CGFloat {
            availableToolbarWidth - 2 * tier.side(leadingChrome: leadingChrome, pillReserve: trailingReserve)
        }
        let tier = tiers.first { width($0) >= minimumWidth } ?? tiers[tiers.count - 1]
        return Layout(
            width: min(LeoActivityCapsulePresentation.maxWidth, max(minimumWidth, width(tier))),
            showsSubtitle: tier.showsSubtitle, showsTitle: tier.showsTitle, showsMoreItem: tier.showsMoreItem,
            showsUpdateItem: tier.showsUpdateItem)
    }
}
