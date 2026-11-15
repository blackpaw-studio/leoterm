import CoreGraphics
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoPluginMeterGeometryTests {
    private func seg(_ value: Double, _ tone: LeoPluginTone = .accent1) -> LeoPluginNode.Meter.Segment {
        .init(value: value, tone: tone)
    }

    @Test
    func segmentsLaySideBySideInProportionToMax() {
        let bars = LeoPluginMeterGeometry.bars([seg(25, .accent1), seg(50, .accent2)], max: 100, width: 200)
        #expect(bars.map(\.x) == [0, 50])
        #expect(bars.map(\.width) == [50, 100])
        #expect(bars.map(\.tone) == [.accent1, .accent2])
    }

    @Test
    func overflowingValuesAreCutAtTheTotalWidth() {
        let bars = LeoPluginMeterGeometry.bars([seg(80), seg(80, .accent2)], max: 100, width: 100)
        #expect(bars.map(\.width) == [80, 20])
        #expect(bars.map(\.x) == [0, 80])
    }

    @Test
    func segmentsPastTheEndAreDropped() {
        let bars = LeoPluginMeterGeometry.bars([seg(100), seg(10, .accent2)], max: 100, width: 100)
        #expect(bars.count == 1)
    }

    @Test
    func emptyAndZeroSegmentsDrawNothing() {
        #expect(LeoPluginMeterGeometry.bars([seg(0)], max: 100, width: 100).isEmpty)
        #expect(LeoPluginMeterGeometry.bars([seg(10)], max: 100, width: 0).isEmpty)
    }

    @Test
    func aSingleSegmentFillsExactlyWhenItEqualsMax() {
        #expect(LeoPluginMeterGeometry.bars([seg(100)], max: 100, width: 56).map(\.width) == [56])
    }

    @Test
    func theSummaryBarIs56By5AndTheBodyBarIsAsWideAsItIsGiven() {
        #expect(LeoPluginMeterGeometry.summarySize == CGSize(width: 56, height: 5))
        #expect(LeoPluginMeterGeometry.bodyHeight == 6)
    }
}
