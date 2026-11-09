import AppKit
import Testing

@testable import Ghostty

struct LeoRowClickRegionTests {
    private let bounds = NSRect(x: 0, y: 0, width: 200, height: 40)
    @Test func theTrailingExclusionStillApplies() {
        let chevron = LeoRowClickRegion(trailingExclusion: 20)
        #expect(!chevron.contains(NSPoint(x: 190, y: 20), in: bounds, isFlipped: false))
        #expect(chevron.contains(NSPoint(x: 100, y: 20), in: bounds, isFlipped: false))
    }
}
