import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoStatsStyleSettingTests {
    @Test func startsOnCapsulesWhenNothingIsStored() {
        #expect(LeoStatsStyleSetting(defaults: LeoInMemoryDefaults()).style == .capsules)
    }

    @Test func choosingAStylePersistsItUnderTheSharedKey() {
        let defaults = LeoInMemoryDefaults()
        let setting = LeoStatsStyleSetting(defaults: defaults)

        setting.style = .rings

        #expect(defaults.string(forKey: LeoStatsStyle.defaultsKey) == "rings")
        #expect(LeoStatsStyleSetting(defaults: defaults).style == .rings, "a fresh read sees the choice")
    }

    @Test func anUnknownStoredValueFallsBackToCapsules() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("holograms", forKey: LeoStatsStyle.defaultsKey)

        #expect(LeoStatsStyleSetting(defaults: defaults).style == .capsules)
    }

    @Test func theStoredNameIsTheStyleRawValue() {
        #expect(LeoStatsStyle.defaultsKey == "LeoStatsStyle")
        #expect(LeoStatsStyle.allCases.map(\.rawValue) == ["capsules", "bars", "rings", "numbers", "off"])
    }
}
