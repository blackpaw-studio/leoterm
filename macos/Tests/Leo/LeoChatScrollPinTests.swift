import Foundation
import Testing

@testable import Ghostty

/// The chat thread stays pinned to the newest message across resizes, mode
/// switches and new messages, unless the reader scrolled up.
struct LeoChatScrollPinTests {
    private static let viewport = CGSize(width: 380, height: 500)

    /// Content 2000 pt tall, scrolled so its bottom is `distance` below the
    /// viewport's bottom edge.
    private static func metrics(
        distance: CGFloat, contentHeight: CGFloat = 2000, viewport: CGSize = viewport
    ) -> LeoChatScrollMetrics {
        LeoChatScrollMetrics(
            contentMinY: viewport.height + distance - contentHeight, contentHeight: contentHeight, viewport: viewport
        )
    }

    /// A pin that has seen `metrics` as a settled user position.
    private static func settled(at metrics: LeoChatScrollMetrics) -> LeoChatScrollPin {
        let first = LeoChatScrollPin().measured(metrics).pin
        return first.measured(metrics).pin
    }

    @Test func startsPinnedAndScrollsToTheNewestOnFirstLayout() {
        let step = LeoChatScrollPin().measured(Self.metrics(distance: 1500))
        #expect(step.scrollToBottom)
        #expect(step.pin.isPinned)
    }

    @Test(arguments: [0, 20, LeoChatScrollPin.tolerance])
    func scrollingWithinTheToleranceStaysPinned(distance: CGFloat) {
        let pin = Self.settled(at: Self.metrics(distance: 0))
        let step = pin.measured(Self.metrics(distance: distance))
        #expect(step.pin.isPinned)
        #expect(!step.scrollToBottom)
    }

    @Test func scrollingUpPastTheToleranceUnpins() {
        let pin = Self.settled(at: Self.metrics(distance: 0))
        let step = pin.measured(Self.metrics(distance: LeoChatScrollPin.tolerance + 1))
        #expect(!step.pin.isPinned)
        #expect(!step.scrollToBottom)
    }

    @Test func scrollingBackDownRepins() {
        let unpinned = Self.settled(at: Self.metrics(distance: 0)).measured(Self.metrics(distance: 300)).pin
        #expect(unpinned.measured(Self.metrics(distance: 10)).pin.isPinned)
    }

    @Test func aNewMessageWhilePinnedFollowsIt() {
        let pin = Self.settled(at: Self.metrics(distance: 0))
        // The content grew by a 120 pt message; the top didn't move.
        let step = pin.measured(Self.metrics(distance: 120, contentHeight: 2120))
        #expect(step.scrollToBottom)
        #expect(step.pin.isPinned)
    }

    @Test func aNewMessageWhileScrolledUpKeepsThePosition() {
        let pin = Self.settled(at: Self.metrics(distance: 0)).measured(Self.metrics(distance: 300)).pin
        let step = pin.measured(Self.metrics(distance: 420, contentHeight: 2120))
        #expect(!step.scrollToBottom)
        #expect(!step.pin.isPinned)
    }

    @Test func aResizeWhilePinnedStaysAtTheBottom() {
        let pin = Self.settled(at: Self.metrics(distance: 0))
        // Narrower: text rewraps taller and the viewport changed.
        let narrow = CGSize(width: 520, height: 500)
        let step = pin.measured(Self.metrics(distance: 260, contentHeight: 2260, viewport: narrow))
        #expect(step.scrollToBottom)
        #expect(step.pin.isPinned)
    }

    @Test func aResizeWhileScrolledUpKeepsThePosition() {
        let pin = Self.settled(at: Self.metrics(distance: 0)).measured(Self.metrics(distance: 300)).pin
        let step = pin.measured(Self.metrics(distance: 560, contentHeight: 2260, viewport: CGSize(width: 520, height: 500)))
        #expect(!step.scrollToBottom)
        #expect(!step.pin.isPinned)
    }

    @Test func aViewportHeightChangeWhilePinnedStaysAtTheBottom() {
        let pin = Self.settled(at: Self.metrics(distance: 0))
        // A taller composer (a reply banner) shrinks the viewport.
        let shorter = CGSize(width: 380, height: 440)
        let step = pin.measured(LeoChatScrollMetrics(contentMinY: -1500, contentHeight: 2000, viewport: shorter))
        #expect(step.scrollToBottom)
        #expect(step.pin.isPinned)
    }

    @Test func resetRepinsForANewThread() {
        let unpinned = Self.settled(at: Self.metrics(distance: 0)).measured(Self.metrics(distance: 300)).pin
        let step = unpinned.reset().measured(Self.metrics(distance: 900, contentHeight: 1400))
        #expect(step.pin.isPinned)
        #expect(step.scrollToBottom)
    }

    @Test func contentShorterThanTheViewportIsPinned() {
        let step = LeoChatScrollPin().measured(LeoChatScrollMetrics(contentMinY: 0, contentHeight: 200, viewport: Self.viewport))
        #expect(step.pin.isPinned)
        #expect(!step.scrollToBottom)
    }
}
