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

        #expect(layout == .init(width: LeoActivityCapsulePresentation.maxWidth, showsSubtitle: true, showsTitle: true, showsMoreItem: true))
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
}
