import CoreGraphics

/// How wide the toolbar's activity capsule is, and what has to yield for it.
///
/// The capsule is centred in the toolbar region right of the sidebar, so
/// whatever sits to its left (the sidebar toggle and traffic lights while
/// the sidebar is collapsed, then the window title) is also taken from its
/// right. AppKit won't shrink a custom-view item to fit: one that doesn't
/// fit goes to the overflow chevron at its preferred width. So the width is
/// chosen from the room, and the rest gives way in order: the subtitle, the
/// title, then the "⋯" item, before the capsule drops below `minimumWidth`
/// (a title stub, the glyph, the badge and the bar).
enum LeoActivityCapsuleSizing {
    static let minimumWidth: CGFloat = 120
    /// What the title with its subtitle, the title alone, and the "⋯" item
    /// (alone, then not at all) keep on each side of the centred capsule.
    static let subtitleSideReserve: CGFloat = 190
    static let titleSideReserve: CGFloat = 100
    static let moreSideReserve: CGFloat = 56
    static let bareSideReserve: CGFloat = 16
    /// The traffic lights and the sidebar toggle, from the window's left
    /// edge, while the sidebar is collapsed.
    static let collapsedSidebarChrome: CGFloat = 140

    struct Layout: Equatable {
        let width: CGFloat
        let showsSubtitle: Bool
        let showsTitle: Bool
        let showsMoreItem: Bool
    }

    private struct Tier {
        let leftReserve: CGFloat
        let rightReserve: CGFloat
        let showsSubtitle: Bool
        let showsTitle: Bool
        let showsMoreItem: Bool
    }

    /// Richest first: the first tier whose capsule reaches `minimumWidth` wins.
    private static let tiers = [
        Tier(leftReserve: subtitleSideReserve, rightReserve: moreSideReserve, showsSubtitle: true, showsTitle: true, showsMoreItem: true),
        Tier(leftReserve: titleSideReserve, rightReserve: moreSideReserve, showsSubtitle: false, showsTitle: true, showsMoreItem: true),
        Tier(leftReserve: 0, rightReserve: moreSideReserve, showsSubtitle: false, showsTitle: false, showsMoreItem: true),
        Tier(leftReserve: 0, rightReserve: bareSideReserve, showsSubtitle: false, showsTitle: false, showsMoreItem: false),
    ]

    /// `leadingChrome` is what sits left of the title inside the region
    /// (`collapsedSidebarChrome` or 0).
    static func layout(availableToolbarWidth: CGFloat, leadingChrome: CGFloat) -> Layout {
        func layout(_ tier: Tier) -> Layout {
            let side = max(leadingChrome + tier.leftReserve, tier.rightReserve)
            return Layout(
                width: min(LeoActivityCapsulePresentation.maxWidth, max(minimumWidth, availableToolbarWidth - 2 * side)),
                showsSubtitle: tier.showsSubtitle, showsTitle: tier.showsTitle, showsMoreItem: tier.showsMoreItem)
        }
        func fits(_ tier: Tier) -> Bool {
            availableToolbarWidth - 2 * max(leadingChrome + tier.leftReserve, tier.rightReserve) >= minimumWidth
        }
        return layout(tiers.first(where: fits) ?? tiers[tiers.count - 1])
    }
}
