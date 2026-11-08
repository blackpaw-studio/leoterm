import Testing

@testable import Ghostty

/// The capsule is centred, so whatever sits left of it (the sidebar toggle
/// and traffic lights when the sidebar is collapsed, then the window title)
/// is also taken from its right. AppKit folds an item that doesn't fit into
/// the overflow chevron instead of shrinking it, so the width is chosen from
/// the room: the subtitle, the update pill, then the title yield before the
/// capsule does. The trailing items (view switch, Interrupt, "⋯") never fold:
/// their room is always reserved.
struct LeoActivityCapsuleSizingTests {
    private typealias Sizing = LeoActivityCapsuleSizing

    @Test func aWideToolbarKeepsEverythingAndTheMaximumWidth() {
        let layout = Sizing.layout(availableToolbarWidth: 1400, leadingChrome: 0)

        #expect(layout == .init(width: LeoActivityCapsulePresentation.maxWidth, showsSubtitle: true, showsTitle: true, showsUpdateItem: true))
    }

    @Test func theCapsuleGetsWhatTheSubtitleLeavesOnEachSide() {
        let layout = Sizing.layout(availableToolbarWidth: 550, leadingChrome: 0)

        let side = max(Sizing.subtitleSideReserve, Sizing.trailingGroupsReserve)
        #expect(layout.width == 550 - 2 * side)
        #expect(layout.showsSubtitle)
    }

    @Test func theSubtitleGoesWhenTheMinimumCapsuleNoLongerFitsBesideIt() {
        // The collapsed sidebar's chrome makes the left side the binding one.
        let chrome = Sizing.collapsedSidebarChrome
        let fits = Sizing.minimumWidth + 2 * (chrome + Sizing.subtitleSideReserve)

        #expect(Sizing.layout(availableToolbarWidth: fits, leadingChrome: chrome).showsSubtitle)
        let layout = Sizing.layout(availableToolbarWidth: fits - 1, leadingChrome: chrome)
        #expect(!layout.showsSubtitle && layout.showsTitle)
        #expect(layout.width == fits - 1 - 2 * (chrome + Sizing.titleSideReserve))
    }

    @Test func theTitleGoesWhenEvenTheTitleAloneLeavesNoRoom() {
        let layout = Sizing.layout(availableToolbarWidth: 560, leadingChrome: Sizing.collapsedSidebarChrome)

        #expect(!layout.showsSubtitle && !layout.showsTitle)
        #expect(layout.width == 560 - 2 * Sizing.trailingGroupsReserve)
    }

    @Test func theCollapsedSidebarsChromeCountsAgainstTheRoomOnTheLeft() {
        let open = Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0)
        let collapsed = Sizing.layout(availableToolbarWidth: 700, leadingChrome: Sizing.collapsedSidebarChrome)

        #expect(collapsed.width < open.width)
    }

    @Test func aNarrowCollapsedWindowDropsTheTitleAndStillShowsTheCapsule() {
        let layout = Sizing.layout(availableToolbarWidth: 480, leadingChrome: Sizing.collapsedSidebarChrome)

        // The trailing groups keep their room, so the capsule sits at its floor.
        #expect(!layout.showsTitle)
        #expect(layout.width == Sizing.minimumWidth)
    }

    @Test func theTrailingGroupsStayReservedAtEveryWidth() {
        // A 480 pt window: the capsule degrades to its floor; nothing takes back the trailing room.
        let narrow = Sizing.layout(availableToolbarWidth: 480, leadingChrome: 0)
        #expect(narrow.width == Sizing.minimumWidth)
        #expect(!narrow.showsSubtitle && !narrow.showsTitle && !narrow.showsUpdateItem)

        // Narrower than the floor: the capsule stops shrinking at `minimumWidth`.
        for width in [300, 100, 0] as [CGFloat] {
            #expect(Sizing.layout(availableToolbarWidth: width, leadingChrome: 0).width == Sizing.minimumWidth)
        }
    }

    @Test func theCapsuleKeepsTheTrailingGroupsRoomOnBothSides() {
        let layout = Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0, trailingReserve: 0)

        #expect(layout.width <= 700 - 2 * Sizing.trailingGroupsReserve)
    }

    @Test func theUpdateItemsWidthIsTakenFromBothSidesOfTheCentredCapsule() {
        let layout = Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0, trailingReserve: 40)

        // Centred: what sits right of the capsule (beside the trailing groups) is also taken from its left.
        #expect(layout.width == 700 - 2 * (Sizing.trailingGroupsReserve + 40))
    }

    @Test func thePillGivesWayAfterTheSubtitleAndBeforeTheTitle() {
        let pill: CGFloat = 100
        let chrome = Sizing.collapsedSidebarChrome
        func layout(_ width: CGFloat) -> Sizing.Layout {
            Sizing.layout(availableToolbarWidth: width, leadingChrome: chrome, trailingReserve: pill)
        }
        func fits(left: CGFloat, pill showsPill: Bool) -> CGFloat {
            Sizing.minimumWidth + 2 * max(chrome + left, Sizing.trailingGroupsReserve + (showsPill ? pill : 0))
        }

        // Room for everything.
        let roomy = layout(fits(left: Sizing.subtitleSideReserve, pill: true))
        #expect(roomy.showsSubtitle && roomy.showsUpdateItem && roomy.showsTitle)
        // Less: the subtitle goes first, the pill stays.
        let noSubtitle = layout(fits(left: Sizing.subtitleSideReserve, pill: true) - 1)
        #expect(!noSubtitle.showsSubtitle && noSubtitle.showsUpdateItem && noSubtitle.showsTitle)
        // Less still: the pill goes, the title stays.
        let noPill = layout(fits(left: Sizing.titleSideReserve, pill: true) - 1)
        #expect(!noPill.showsUpdateItem && noPill.showsTitle)
        // Only then the title; the capsule itself shrinks last, to its floor.
        let noTitle = layout(fits(left: Sizing.titleSideReserve, pill: false) - 1)
        #expect(!noTitle.showsTitle && !noTitle.showsUpdateItem)
        #expect(layout(100).width == Sizing.minimumWidth)
    }

    @Test func aDroppedPillReservesNothing() {
        let layout = Sizing.layout(availableToolbarWidth: 500, leadingChrome: 0, trailingReserve: 100)

        #expect(!layout.showsUpdateItem)
        #expect(layout.width == 500 - 2 * max(Sizing.titleSideReserve, Sizing.trailingGroupsReserve))
    }

    @Test func noUpdateItemLeavesTheLayoutUnchanged() {
        #expect(Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0, trailingReserve: 0)
            == Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0))
    }
}
