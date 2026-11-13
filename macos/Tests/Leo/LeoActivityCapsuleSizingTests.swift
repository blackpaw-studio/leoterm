import Testing

@testable import Ghostty

/// The capsule is centred, so whatever sits left of it (the sidebar toggle
/// and traffic lights when the sidebar is collapsed, then the window title)
/// is also taken from its right. AppKit folds an item that doesn't fit into
/// the overflow chevron instead of shrinking it, so the width is chosen from
/// the room: the subtitle, the tool toggles, Interrupt, the update pill, then
/// the title yield before the capsule does. Their room is reserved while
/// they fit; the view switch and "⋯" never fold, so their room always is.
struct LeoActivityCapsuleSizingTests {
    private typealias Sizing = LeoActivityCapsuleSizing

    @Test func aWideToolbarKeepsEverythingAndTheMaximumWidth() {
        let layout = Sizing.layout(availableToolbarWidth: 1400, leadingChrome: 0)

        #expect(
            layout == .init(
                width: LeoActivityCapsulePresentation.maxWidth, showsSubtitle: true, showsTitle: true, showsUpdateItem: true,
                isCentered: true, showsToggles: true, showsInterrupt: true, titleWidth: Sizing.maxTitleWidth))
    }

    @Test func theTitleItemGetsTheRoomLeftOfTheCentredCapsuleUpToItsMaximum() {
        // Wide: the trailing groups' room on the left is more than the title needs.
        #expect(Sizing.layout(availableToolbarWidth: 1400, leadingChrome: 0).titleWidth == Sizing.maxTitleWidth)
        // With the toggles folded, the left side is what the trailing reserve leaves, less the gap.
        let folded = Sizing.layout(availableToolbarWidth: 800, leadingChrome: 0)
        #expect(!folded.showsToggles && folded.titleWidth == Sizing.trailingReserveWithoutToggles - Sizing.titleGap)
        // The collapsed sidebar's chrome sits left of the title and is not its room.
        let collapsed = Sizing.layout(availableToolbarWidth: 1100, leadingChrome: 300)
        #expect(collapsed.showsSubtitle && collapsed.titleWidth == Sizing.subtitleSideReserve - Sizing.titleGap)
    }

    @Test func noTitleItemIsLeftOnceTheTitleHasGoneAndWithNoRoomToCentre() {
        let noTitle = Sizing.layout(
            availableToolbarWidth: Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal, leadingChrome: Sizing.trailingReserveMinimal)
        #expect(!noTitle.showsTitle && noTitle.titleWidth == 0)
        #expect(Sizing.layout(availableToolbarWidth: 100, leadingChrome: 0).titleWidth == 0)
    }

    @Test func theCapsuleGetsWhatTheSubtitleLeavesOnEachSide() {
        let layout = Sizing.layout(availableToolbarWidth: 1000, leadingChrome: 0)

        let side = max(Sizing.subtitleSideReserve, Sizing.trailingGroupsReserve)
        #expect(layout.width == 1000 - 2 * side)
        #expect(layout.showsSubtitle)
    }

    @Test func theSubtitleGoesWhenTheMinimumCapsuleNoLongerFitsBesideIt() {
        // A sidebar chrome wide enough to make the title's side the binding one.
        let chrome: CGFloat = 300
        let fits = Sizing.minimumWidth + 2 * (chrome + Sizing.subtitleSideReserve)

        #expect(Sizing.layout(availableToolbarWidth: fits, leadingChrome: chrome).showsSubtitle)
        let layout = Sizing.layout(availableToolbarWidth: fits - 1, leadingChrome: chrome)
        #expect(!layout.showsSubtitle && layout.showsTitle)
        #expect(layout.width == fits - 1 - 2 * max(chrome + Sizing.titleSideReserve, Sizing.trailingGroupsReserve))
    }

    @Test func theToolTogglesFoldBeforeInterruptAndBothBeforeTheTitle() {
        func layout(_ width: CGFloat) -> Sizing.Layout { Sizing.layout(availableToolbarWidth: width, leadingChrome: 0) }
        let full = Sizing.minimumWidth + 2 * Sizing.trailingGroupsReserve
        // Room for every trailing item: the capsule is centred with all of them reserved.
        #expect(layout(full).isCentered && layout(full).showsToggles && layout(full).showsInterrupt)
        // Less: the toggles fold, Interrupt stays.
        let noToggles = layout(full - 1)
        #expect(!noToggles.showsToggles && noToggles.showsInterrupt && noToggles.isCentered && noToggles.showsTitle)
        #expect(noToggles.width == full - 1 - 2 * Sizing.trailingReserveWithoutToggles)
        // Less still: Interrupt folds too; the title is still there.
        let minimal = layout(Sizing.minimumWidth + 2 * Sizing.trailingReserveWithoutToggles - 1)
        #expect(!minimal.showsToggles && !minimal.showsInterrupt && minimal.showsTitle)
        // Only after both: the title goes.
        let noTitle = layout(Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal - 1)
        #expect(!noTitle.showsTitle)
    }

    @Test func theViewSwitchAndMoreKeepTheirRoomAtEveryWidth() {
        for width in [Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal - 1, 300, 0] as [CGFloat] {
            let layout = Sizing.layout(availableToolbarWidth: width, leadingChrome: 0)
            #expect(!layout.showsToggles && !layout.showsInterrupt, "\(width)")
            if !layout.isCentered { #expect(layout.width + Sizing.capsuleGap + Sizing.trailingReserveMinimal <= max(width, Sizing.compactWidth + Sizing.capsuleGap + Sizing.trailingReserveMinimal)) }
        }
    }

    @Test func theCollapsedSidebarsChromeCountsAgainstTheRoomOnTheLeft() {
        // Wide enough chrome to bind: the trailing groups' room is the larger side otherwise.
        let open = Sizing.layout(availableToolbarWidth: 1100, leadingChrome: 0)
        let collapsed = Sizing.layout(availableToolbarWidth: 1100, leadingChrome: 300)

        #expect(collapsed.width < open.width)
    }

    @Test func aNarrowCollapsedWindowDropsTheTitleAndStillShowsTheCapsule() {
        let width = Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal
        let layout = Sizing.layout(availableToolbarWidth: width, leadingChrome: Sizing.trailingReserveMinimal)

        // The trailing groups keep their room, so the capsule sits at its floor.
        #expect(!layout.showsTitle)
        #expect(layout.width == Sizing.minimumWidth)
    }

    @Test func theTrailingGroupsStayReservedAtEveryWidth() {
        // Too narrow to centre the capsule: it gives up centring and takes what the trailing groups leave.
        let narrow = Sizing.layout(availableToolbarWidth: Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal - 1, leadingChrome: 0)
        #expect(narrow.width == Sizing.minimumWidth)
        #expect(!narrow.showsSubtitle && !narrow.showsTitle && !narrow.showsUpdateItem && !narrow.isCentered)

        let tight = Sizing.layout(availableToolbarWidth: 400, leadingChrome: 0)
        // The uncentred capsule keeps the measured widths only (no centring slack), plus its own clearance.
        let measuredMinimal = Sizing.trailingReserveMinimal - Sizing.itemSlack
        #expect(tight.width == 400 - measuredMinimal - Sizing.capsuleGap - Sizing.uncentredClearance)

        // Narrower than the compact capsule: it stops shrinking there.
        for width in [100, 0] as [CGFloat] {
            #expect(Sizing.layout(availableToolbarWidth: width, leadingChrome: 0).width == Sizing.compactWidth)
        }
    }

    @Test func aWindowAt560WithTheSidebarOpenLeavesRoomForTheSwitchAndMore() {
        // 560 pt window, 200 pt sidebar: 360 pt of toolbar. The switch (with its
        // labels) and "⋯" never fold, so the capsule gives way to them.
        let layout = Sizing.layout(availableToolbarWidth: 360, leadingChrome: 0)

        #expect(!layout.isCentered)
        #expect(layout.width >= Sizing.compactWidth)
        #expect(layout.width + Sizing.capsuleGap + Sizing.trailingReserveMinimal - Sizing.itemSlack <= 360)
    }

    @Test func theCapsuleStaysCentredWhileItFitsCentred() {
        #expect(Sizing.layout(availableToolbarWidth: Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal, leadingChrome: 0).isCentered)
        #expect(!Sizing.layout(availableToolbarWidth: Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal - 1, leadingChrome: 0).isCentered)
    }

    @Test func theCapsuleKeepsTheTrailingGroupsRoomOnBothSides() {
        let layout = Sizing.layout(availableToolbarWidth: 1100, leadingChrome: 0, trailingReserve: 0)

        #expect(layout.width <= 1100 - 2 * Sizing.trailingGroupsReserve)
    }

    @Test func theUpdateItemsWidthIsTakenFromBothSidesOfTheCentredCapsule() {
        let layout = Sizing.layout(availableToolbarWidth: 1100, leadingChrome: 0, trailingReserve: 40)

        // Centred: what sits right of the capsule (beside the trailing groups) is also taken from its left.
        #expect(layout.width == 1100 - 2 * (Sizing.trailingGroupsReserve + 40))
    }

    @Test func thePillGivesWayAfterTheSubtitleAndBeforeTheToolToggles() {
        let pill: CGFloat = 100
        let chrome = Sizing.collapsedSidebarChrome
        func layout(_ width: CGFloat) -> Sizing.Layout {
            Sizing.layout(availableToolbarWidth: width, leadingChrome: chrome, trailingReserve: pill)
        }
        func fits(left: CGFloat, trailing: CGFloat, pill showsPill: Bool) -> CGFloat {
            Sizing.minimumWidth + 2 * max(chrome + left, trailing + (showsPill ? pill : 0))
        }
        let groups = Sizing.trailingGroupsReserve
        let minimal = Sizing.trailingReserveMinimal

        // Room for everything.
        let roomy = layout(fits(left: Sizing.subtitleSideReserve, trailing: groups, pill: true))
        #expect(roomy.showsSubtitle && roomy.showsUpdateItem && roomy.showsToggles && roomy.showsTitle)
        // Less: the pill goes while the toggles stay.
        let noPill = layout(fits(left: Sizing.titleSideReserve, trailing: groups, pill: true) - 1)
        #expect(!noPill.showsUpdateItem && noPill.showsToggles && noPill.showsTitle)
        // Then the toggles.
        let noToggles = layout(fits(left: Sizing.titleSideReserve, trailing: groups, pill: false) - 1)
        #expect(!noToggles.showsToggles && noToggles.showsInterrupt && noToggles.showsTitle)
        // Only after Interrupt too the title; the capsule itself shrinks last, to its floor.
        let noTitle = layout(fits(left: Sizing.titleSideReserve, trailing: minimal, pill: false) - 1)
        #expect(!noTitle.showsTitle && !noTitle.showsUpdateItem)
        #expect(layout(100).width == Sizing.compactWidth)
    }

    @Test func aDroppedPillReservesNothing() {
        let width = Sizing.minimumWidth + 2 * Sizing.trailingReserveMinimal + 20
        let layout = Sizing.layout(availableToolbarWidth: width, leadingChrome: 0, trailingReserve: 100)

        #expect(!layout.showsUpdateItem)
        #expect(layout.width == width - 2 * max(Sizing.titleSideReserve, Sizing.trailingReserveMinimal))
    }

    @Test func noUpdateItemLeavesTheLayoutUnchanged() {
        #expect(Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0, trailingReserve: 0)
            == Sizing.layout(availableToolbarWidth: 700, leadingChrome: 0))
    }
}
