import Foundation
import Testing

@testable import Ghostty

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

    @Test func aHiddenSidebarAddsNothing() {
        let size = LeoInitialSizeDecision.contentSize(initialSize: initialSize, sidebarWidth: nil, dividerWidth: 1)
        #expect(size == initialSize)
    }

    @Test func noConfiguredSizeGivesNoSize() {
        #expect(LeoInitialSizeDecision.contentSize(initialSize: nil, sidebarWidth: 220, dividerWidth: 1) == nil)
        #expect(LeoInitialSizeDecision.contentSize(initialSize: nil, sidebarWidth: nil, dividerWidth: 1) == nil)
    }
}
