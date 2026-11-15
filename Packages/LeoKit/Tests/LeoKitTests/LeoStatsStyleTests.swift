import Testing

@testable import LeoKit

struct LeoStatsStyleTests {
    @Test func capsulesIsTheDefault() {
        #expect(LeoStatsStyle.default == .capsules)
        #expect(LeoStatsStyle(storedValue: nil) == .capsules)
    }

    @Test func storedValueRoundTripsEveryStyle() {
        for style in LeoStatsStyle.allCases {
            #expect(LeoStatsStyle(storedValue: style.rawValue) == style)
        }
        #expect(LeoStatsStyle.allCases.map(\.rawValue) == ["capsules", "bars", "rings", "numbers", "off"])
    }

    @Test func unknownStoredValueFallsBackToDefault() {
        #expect(LeoStatsStyle(storedValue: "sparklines") == .capsules)
    }

    @Test func offStopsPollingAndHidesMeters() {
        #expect(!LeoStatsStyle.off.showsMeters)
        for style in LeoStatsStyle.allCases where style != .off {
            #expect(style.showsMeters)
        }
    }
}
