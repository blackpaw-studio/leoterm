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

    @Test func scrollingBackNearTheBottomRepins() {
        var pin = ChatScrollPin()
        pin.userScrolled(metrics(offset: 200))
        pin.userScrolled(metrics(offset: 410 - ChatScrollPin.nearBottom + 1))
        #expect(pin.isPinned)
    }

    @Test func justOutsideTheThresholdStaysUnpinned() {
        var pin = ChatScrollPin()
        pin.userScrolled(metrics(offset: 410 - ChatScrollPin.nearBottom - 1))
        #expect(!pin.isPinned)
    }

    @Test func releasingStopsFollowingUntilTheReaderReturnsToTheBottom() {
        var pin = ChatScrollPin()
        pin.release()
        #expect(pin.correction(for: metrics(offset: 0)) == nil)
        pin.userScrolled(metrics(offset: 410))
        #expect(pin.isPinned)
    }
}
