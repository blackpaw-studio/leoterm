import CoreGraphics

/// How wide the toolbar's activity capsule is, given the toolbar region to
/// the right of the sidebar. AppKit won't shrink a custom-view item to fit:
/// it sends an item that doesn't fit at its preferred width to the overflow
/// chevron. So the width is set from what is available: the capsule grows to
/// `LeoActivityCapsulePresentation.maxWidth` and gives way down to
/// `minimumWidth` (a title stub, the glyph, the badge and the bar), leaving
/// room for the title and the "⋯" item, which are the first to yield below it.
enum LeoActivityCapsuleSizing {
    static let minimumWidth: CGFloat = 120
    /// What the window title and subtitle keep before the capsule takes more.
    static let titleReserve: CGFloat = 160
    /// The "⋯" item's room, margins included.
    static let moreReserve: CGFloat = 80

    static func width(availableToolbarWidth: CGFloat) -> CGFloat {
        min(LeoActivityCapsulePresentation.maxWidth, max(minimumWidth, availableToolbarWidth - titleReserve - moreReserve))
    }
}
