import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-086: a window's first content sizes it only while it has never been
/// on screen, and then from the configured size, never the SwiftUI view's.
struct LeoInitialSizeDecisionTests {
    private let initialSize = CGSize(width: 640, height: 384)

    @Test func aWindowAwaitingItsFirstPresentationIsSized() {
        #expect(LeoInitialSizeDecision.shouldSize(isVisible: false, isAwaitingPresentation: true))
    }

    @Test func aShownWindowIsNeverSized() {
        #expect(!LeoInitialSizeDecision.shouldSize(isVisible: true, isAwaitingPresentation: false))
        #expect(!LeoInitialSizeDecision.shouldSize(isVisible: true, isAwaitingPresentation: true))
    }

    /// Minimized, or its app hidden: not visible, but it has been shown.
    @Test func aWindowShownBeforeButNotVisibleNowIsNotSized() {
        #expect(!LeoInitialSizeDecision.shouldSize(isVisible: false, isAwaitingPresentation: false))
    }

    @Test func theSizeIsTheConfiguredSizePlusTheSidebarAndItsDivider() {
        let size = LeoInitialSizeDecision.contentSize(initialSize: initialSize, sidebarWidth: 220, dividerWidth: 1)
        #expect(size == CGSize(width: 640 + 220 + 1, height: 384))
    }

    /// B-091: beside the sidebar, the terminal gets at least the content
    /// minimum, so the sidebar's maximum (which leaves the content that)
    /// never clamps the stored width the window opens with.
    @Test func aNarrowConfiguredTerminalOpensWideEnoughForTheStoredSidebar() {
        let narrow = CGSize(width: 300, height: 384)

        let size = LeoInitialSizeDecision.contentSize(initialSize: narrow, sidebarWidth: 260, dividerWidth: 1)

        #expect(size == CGSize(width: LeoSidebarSplitMetrics.contentMinimumWidth + 260 + 1, height: 384))
    }

    /// Without the sidebar there's nothing to clamp: the configured size.
    @Test func aNarrowConfiguredTerminalWithoutTheSidebarKeepsItsSize() {
        let narrow = CGSize(width: 300, height: 384)

        #expect(LeoInitialSizeDecision.contentSize(initialSize: narrow, sidebarWidth: nil, dividerWidth: 1) == narrow)
    }

    @Test func aHiddenSidebarAddsNothing() {
        let size = LeoInitialSizeDecision.contentSize(initialSize: initialSize, sidebarWidth: nil, dividerWidth: 1)
        #expect(size == initialSize)
    }

    @Test func noConfiguredSizeGivesNoSize() {
        #expect(LeoInitialSizeDecision.contentSize(initialSize: nil, sidebarWidth: 220, dividerWidth: 1) == nil)
        #expect(LeoInitialSizeDecision.contentSize(initialSize: nil, sidebarWidth: nil, dividerWidth: 1) == nil)
    }

    /// B-091 on a small screen: the window the first content asks for
    /// (content minimum + the stored sidebar + divider) fits a 1024x768
    /// visible frame, so the sidebar keeps its stored width. Screen-independent:
    /// the frame is injected, never read from the machine's display.
    @Test func aNarrowConfiguredTerminalOnASmallScreenKeepsTheStoredSidebar() {
        let stored: CGFloat = 420
        let asked = LeoInitialSizeDecision.contentSize(
            initialSize: CGSize(width: 300, height: 384), sidebarWidth: stored, dividerWidth: LeoSidebarSplitMetrics.dividerWidth)!

        let fitted = LeoInitialSizeDecision.fittedContentSize(
            asked, chrome: CGSize(width: 0, height: 28), visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 768))

        let sidebar = fitted.width - LeoSidebarSplitMetrics.contentMinimumWidth - LeoSidebarSplitMetrics.dividerWidth
        #expect(abs(sidebar - stored) <= 1, "sidebar \(sidebar), stored \(stored)")
    }

    @Test func aContentSizeLargerThanTheVisibleFrameShrinksToItsContentArea() {
        let fitted = LeoInitialSizeDecision.fittedContentSize(
            CGSize(width: 2000, height: 1200), chrome: CGSize(width: 0, height: 28),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(fitted == CGSize(width: 1440, height: 872))
    }
}
