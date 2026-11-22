import Foundation
import Testing

@testable import LeoKit

struct LeoPluginValueMeterPresentationTests {
    private func presentation(
        value: Double, valueText: String? = "42%", detail: String? = "resets in 2h 14m", tone: LeoPluginMeterTone = .success
    ) -> LeoPluginValueMeterPresentation {
        LeoPluginValueMeterPresentation(LeoPluginNode.ValueMeter(label: "Session", value: value, valueText: valueText, detail: detail, tone: tone))
    }

    @Test func voiceOverReadsLabelValueTextAndDetail() {
        #expect(presentation(value: 0.42).accessibilityLabel == "Session, 42%, resets in 2h 14m")
    }

    @Test func voiceOverSkipsMissingParts() {
        #expect(presentation(value: 0.42, valueText: nil).accessibilityLabel == "Session, resets in 2h 14m")
        #expect(presentation(value: 0.42, valueText: nil, detail: nil).accessibilityLabel == "Session")
        #expect(presentation(value: 0.42, detail: "").accessibilityLabel == "Session, 42%")
    }

    @Test func theAccessibilityValueIsAWholePercent() {
        #expect(presentation(value: 0.424).accessibilityPercent == 42)
        #expect(presentation(value: 1).accessibilityPercent == 100)
    }

    @Test func eachToneMapsToItsRendererTone() {
        #expect(presentation(value: 0, tone: .neutral).tone == .secondary)
        #expect(presentation(value: 0, tone: .success).tone == .success)
        #expect(presentation(value: 0, tone: .warning).tone == .warning)
        #expect(presentation(value: 0, tone: .failure).tone == .failure)
    }

    @Test func warningAndFailureEmphasiseTheValueTextSoToneIsNotColourAlone() {
        #expect(!presentation(value: 0, tone: .neutral).emphasizesValueText)
        #expect(!presentation(value: 0, tone: .success).emphasizesValueText)
        #expect(presentation(value: 0, tone: .warning).emphasizesValueText)
        #expect(presentation(value: 0, tone: .failure).emphasizesValueText)
    }

    @Test func anEmptyMeterDrawsNoFill() {
        #expect(presentation(value: 0).fillWidth(trackWidth: 200, trackHeight: 6) == 0)
    }

    @Test func aTinyValueStillShowsAsADotNoNarrowerThanTheTrackIsHigh() {
        #expect(presentation(value: 0.001).fillWidth(trackWidth: 200, trackHeight: 6) == 6)
    }

    @Test func theFillIsTheValuesShareOfTheTrackAndNeverPassesIt() {
        #expect(presentation(value: 0.5).fillWidth(trackWidth: 200, trackHeight: 6) == 100)
        #expect(presentation(value: 1).fillWidth(trackWidth: 200, trackHeight: 6) == 200)
        // A track narrower than its height can't fit the minimum dot.
        #expect(presentation(value: 0.1).fillWidth(trackWidth: 4, trackHeight: 6) == 4)
    }

    @Test func aZeroWidthTrackDrawsNothing() {
        #expect(presentation(value: 0.5).fillWidth(trackWidth: 0, trackHeight: 6) == 0)
    }
}
