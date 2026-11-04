import Testing

@testable import Ghostty

/// The capsule's width follows the room right of the sidebar: it caps at
/// 500 pt, and gives way to a small minimum so it still shows in a narrow
/// window.
struct LeoActivityCapsuleSizingTests {
    @Test func aWideToolbarGetsTheMaximumWidth() {
        #expect(LeoActivityCapsuleSizing.width(availableToolbarWidth: 1400) == LeoActivityCapsulePresentation.maxWidth)
    }

    @Test func aNarrowerToolbarGivesTheCapsuleWhatTheTitleAndMenuLeave() {
        let width = LeoActivityCapsuleSizing.width(availableToolbarWidth: 550)

        #expect(width == 550 - LeoActivityCapsuleSizing.titleReserve - LeoActivityCapsuleSizing.moreReserve)
    }

    @Test func aNarrowWindowStillShowsTheMinimumCapsule() {
        #expect(LeoActivityCapsuleSizing.width(availableToolbarWidth: 220) == LeoActivityCapsuleSizing.minimumWidth)
        #expect(LeoActivityCapsuleSizing.width(availableToolbarWidth: 0) == LeoActivityCapsuleSizing.minimumWidth)
    }
}
