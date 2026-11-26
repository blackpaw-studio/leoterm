import Foundation
import Testing

@testable import Ghostty

/// Settings ▸ General ▸ "Open images in full window" (B-458): off until the
/// user turns it on, remembered in the Mac's defaults.
@MainActor
struct LeoChatImageOpenSettingTests {
    @Test func isOffByDefault() {
        #expect(!LeoChatImageOpenSetting(defaults: LeoInMemoryDefaults()).opensFullWindow)
        #expect(!LeoChatImageOpenSetting.isOn(in: LeoInMemoryDefaults()))
    }

    @Test func aChoiceIsStoredAndReadBack() {
        let defaults = LeoInMemoryDefaults()
        let setting = LeoChatImageOpenSetting(defaults: defaults)
        setting.opensFullWindow = true
        #expect(LeoChatImageOpenSetting.isOn(in: defaults))
        #expect(LeoChatImageOpenSetting(defaults: defaults).opensFullWindow)
        setting.opensFullWindow = false
        #expect(!LeoChatImageOpenSetting.isOn(in: defaults))
    }
}
