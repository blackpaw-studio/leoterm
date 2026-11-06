import Testing

@testable import Ghostty

/// The capsule is centred, so whatever sits left of it (the sidebar toggle
/// and traffic lights when the sidebar is collapsed, then the window title)
/// is also taken from its right. AppKit folds an item that doesn't fit into
/// the overflow chevron instead of shrinking it, so the width is chosen from
/// the room: the title yields before the capsule does, then the "⋯" item.
struct LeoActivityCapsuleSizingTests {
    private typealias Sizing = LeoActivityCapsuleSizing

    @Test func aWideToolbarKeepsEverythingAndTheMaximumWidth() {
        let layout = Sizing.layout(availableToolbarWidth: 1400, leadingChrome: 0)

        #expect(layout == .init(width: LeoActivityCapsulePresentation.maxWidth, showsSubtitle: true, showsTitle: true, showsMoreItem: true, showsUpdateItem: true))
    }

    @Test func theCapsuleGetsWhatTheSubtitleLeavesOnEachSide() {
        let layout = Sizing.layout(availableToolbarWidth: 550, leadingChrome: 0)

        #expect(layout.width == 550 - 2 * Sizing.subtitleSideReserve)
        #expect(layout.showsSubtitle)
    }

    @Test func theSubtitleGoesWhenTheMinimumCapsuleNoLongerFitsBesideIt() {
        let fits = Sizing.minimumWidth + 2 * Sizing.subtitleSideReserve

        #expect(Sizing.layout(availableToolbarWidth: fits, leadingChrome: 0).showsSubtitle)
        let layout = Sizing.layout(availableToolbarWidth: fits - 1, leadingChrome: 0)
        #expect(!layout.showsSubtitle && layout.showsTitle)
        #expect(layout.width == fits - 1 - 2 * Sizing.titleSideReserve)
    }

    @Test func theTitleGoesWhenEvenTheTitleAloneLeavesNoRoom() {
        let layout = Sizing.layout(availableToolbarWidth: 280, leadingChrome: 0)

        #expect(!layout.showsSubtitle && !layout.showsTitle)
        #expect(layout.showsMoreItem)
        #expect(layout.width == 280 - 2 * Sizing.moreSideReserve)
    }

    @Test func theCollapsedSidebarsChromeCountsAgainstTheRoomOnTheLeft() {
        let open = Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0)
        let collapsed = Sizing.layout(availableToolbarWidth: 700, leadingChrome: Sizing.collapsedSidebarChrome)

        #expect(collapsed.width < open.width)
    }

    @Test func aNarrowCollapsedWindowDropsTheTitleAndStillShowsTheCapsule() {
        let layout = Sizing.layout(availableToolbarWidth: 480, leadingChrome: Sizing.collapsedSidebarChrome)

        #expect(!layout.showsTitle)
        #expect(layout.width >= Sizing.minimumWidth)
        #expect(layout.width == 480 - 2 * Sizing.collapsedSidebarChrome)
    }

    @Test func theMoreItemGoesOnlyWhenTheMinimumCapsuleFitsWithoutIt() {
        let layout = Sizing.layout(availableToolbarWidth: 100, leadingChrome: 0)

        #expect(!layout.showsMoreItem)
        #expect(layout.width == Sizing.minimumWidth)
    }

    @Test func theUpdateItemsWidthIsTakenFromBothSidesOfTheCentredCapsule() {
        let layout = Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0, trailingReserve: 200)

        // Centred: what sits right of the capsule (beside "⋯") is also taken from its left.
        #expect(layout.width == 700 - 2 * (Sizing.moreSideReserve + 200))
        #expect(layout.showsMoreItem)
    }

    @Test func thePillGivesWayAfterTheSubtitleAndBeforeTheTitle() {
        let pill: CGFloat = 100
        func layout(_ width: CGFloat) -> Sizing.Layout { Sizing.layout(availableToolbarWidth: width, leadingChrome: 0, trailingReserve: pill) }

        // Room for everything: the subtitle needs 190 a side, the pill 156.
        let roomy = layout(Sizing.minimumWidth + 2 * Sizing.subtitleSideReserve)
        #expect(roomy.showsSubtitle && roomy.showsUpdateItem && roomy.showsTitle)
        // Less: the subtitle goes first, the pill stays.
        let noSubtitle = layout(Sizing.minimumWidth + 2 * Sizing.subtitleSideReserve - 1)
        #expect(!noSubtitle.showsSubtitle && noSubtitle.showsUpdateItem && noSubtitle.showsTitle)
        // Less still: the pill goes, the title stays.
        let noPill = layout(Sizing.minimumWidth + 2 * (Sizing.moreSideReserve + pill) - 1)
        #expect(!noPill.showsUpdateItem && noPill.showsTitle && noPill.showsMoreItem)
        // Only then the title, then "⋯".
        let noTitle = layout(Sizing.minimumWidth + 2 * Sizing.titleSideReserve - 1)
        #expect(!noTitle.showsTitle && !noTitle.showsUpdateItem && noTitle.showsMoreItem)
        #expect(!layout(100).showsMoreItem)
    }

    @Test func aDroppedPillReservesNothing() {
        let layout = Sizing.layout(availableToolbarWidth: 400, leadingChrome: 0, trailingReserve: 100)

        #expect(!layout.showsUpdateItem)
        #expect(layout.width == 400 - 2 * Sizing.titleSideReserve)
    }

    @Test func noUpdateItemLeavesTheLayoutUnchanged() {
        #expect(Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0, trailingReserve: 0)
            == Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0))
    }
}
