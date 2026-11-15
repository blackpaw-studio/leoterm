import CoreGraphics
import Testing

@testable import LeoFeatures

struct ChatScrollPinTests {
    /// A 600pt list showing 1000pt of content, with a 10pt bottom inset.
    private func metrics(offset: CGFloat, content: CGFloat = 1_000, bounds: CGFloat = 600) -> ChatScrollMetrics {
        ChatScrollMetrics(offsetY: offset, contentHeight: content, boundsHeight: bounds, insetTop: 100, insetBottom: 10)
    }

    @Test func bottomOffsetShowsTheLastPointAboveTheInset() {
        #expect(metrics(offset: 0).bottomOffsetY == 410)
    }

    @Test func shortContentRestsAtTheTop() {
        let short = metrics(offset: -100, content: 200)
        #expect(short.bottomOffsetY == -100)
        #expect(short.distanceFromBottom == 0)
    }

    @Test func startsPinnedAndCorrectsToTheBottomOfTheContent() {
        let pin = ChatScrollPin()
        #expect(pin.isPinned)
        #expect(pin.correction(for: metrics(offset: 0)) == 410)
    }

    @Test func noCorrectionWhileAlreadyAtTheBottom() {
        #expect(ChatScrollPin().correction(for: metrics(offset: 410)) == nil)
        #expect(ChatScrollPin().correction(for: metrics(offset: 409.8)) == nil)
    }

    /// The keyboard shrinks the list: the bottom moves, the pin follows it.
    @Test func followsABoundsChangeWhilePinned() {
        let pin = ChatScrollPin()
        #expect(pin.correction(for: metrics(offset: 410, bounds: 300)) == 710)
    }

    @Test func scrollingUpUnpinsAndStopsCorrecting() {
        var pin = ChatScrollPin()
        pin.userScrolled(metrics(offset: 200))
        #expect(!pin.isPinned)
        #expect(pin.correction(for: metrics(offset: 200)) == nil)
    }

    @Test func scrollingBackToTheBottomRepins() {
        var pin = ChatScrollPin()
        pin.userScrolled(metrics(offset: 200))
        pin.userScrolled(metrics(offset: 410 - ChatScrollPin.bottomTolerance))
        #expect(pin.isPinned)
    }

    /// A reader nudging up a few lines and letting go must stay put.
    @Test func lettingGoAFewLinesAboveTheBottomStaysUnpinned() {
        var pin = ChatScrollPin()
        pin.userScrolled(metrics(offset: 410 - 40))
        #expect(!pin.isPinned)
        #expect(pin.correction(for: metrics(offset: 410 - 40)) == nil)
        pin.userScrolled(metrics(offset: 410 - ChatScrollPin.bottomTolerance - 1))
        #expect(!pin.isPinned)
    }

    /// New messages grow the content; a reader who scrolled up isn't moved.
    @Test func incomingContentLeavesAnUnpinnedReaderWhereTheyAre() {
        var pin = ChatScrollPin()
        pin.userScrolled(metrics(offset: 200))
        let grown = metrics(offset: 200, content: 1_400)
        #expect(pin.correction(for: grown) == nil)
        #expect(!pin.isPinned)
    }

    @Test func releasingStopsFollowingUntilTheReaderReturnsToTheBottom() {
        var pin = ChatScrollPin()
        pin.release()
        #expect(pin.correction(for: metrics(offset: 0)) == nil)
        pin.userScrolled(metrics(offset: 410))
        #expect(pin.isPinned)
    }

    @Test func sendingRepinsAReaderWhoScrolledUp() {
        var pin = ChatScrollPin()
        pin.userScrolled(metrics(offset: 200))
        pin.userSent()
        #expect(pin.isPinned)
        #expect(pin.correction(for: metrics(offset: 200)) == 410)
    }
}
