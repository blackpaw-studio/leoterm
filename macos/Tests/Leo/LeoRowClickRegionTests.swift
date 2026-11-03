import AppKit
import Testing

@testable import Ghostty

struct LeoRowClickRegionTests {
    private let bounds = NSRect(x: 0, y: 0, width: 200, height: 40)
    private let region = LeoRowClickRegion(trailingExclusion: 0, bottomExclusion: 14, bottomLeading: 22, bottomTrailing: 7)

    @Test func theBarsFrameIsNotARowClick() {
        #expect(!region.contains(NSPoint(x: 100, y: 5), in: bounds, isFlipped: false))
    }

    @Test func theStripUnderTheStateSymbolStaysClickable() {
        #expect(region.contains(NSPoint(x: 8, y: 5), in: bounds, isFlipped: false))
    }

    @Test func thePaddingRightOfTheBarStaysClickable() {
        #expect(region.contains(NSPoint(x: 197, y: 5), in: bounds, isFlipped: false))
    }

    @Test func aboveTheStripIsClickable() {
        #expect(region.contains(NSPoint(x: 100, y: 20), in: bounds, isFlipped: false))
    }

    @Test func aFlippedViewMeasuresFromItsBottomEdge() {
        #expect(!region.contains(NSPoint(x: 100, y: 35), in: bounds, isFlipped: true))
        #expect(region.contains(NSPoint(x: 100, y: 5), in: bounds, isFlipped: true))
    }

    @Test func theTrailingExclusionStillApplies() {
        let chevron = LeoRowClickRegion(trailingExclusion: 20)
        #expect(!chevron.contains(NSPoint(x: 190, y: 20), in: bounds, isFlipped: false))
        #expect(chevron.contains(NSPoint(x: 100, y: 20), in: bounds, isFlipped: false))
    }
}
