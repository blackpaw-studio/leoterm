import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoPluginToneTests {
    @Test(arguments: LeoPluginTone.allCases)
    func everyToneMapsToAColour(_ tone: LeoPluginTone) {
        #expect(LeoPluginRenderStyle.color(for: tone).alphaComponent > 0)
    }

    @Test
    func accentTonesAreDistinct() {
        let accents: [LeoPluginTone] = [.accent1, .accent2, .accent3, .accent4, .accent5, .accent6]
        let names = Set(accents.map { LeoPluginRenderStyle.color(for: $0).description })
        #expect(names.count == accents.count)
    }

    @Test
    func statusTonesReuseTheSidebarTints() {
        #expect(LeoPluginRenderStyle.color(for: .success) == LeoPluginRenderStyle.nsColor(for: .tint(.green)))
        #expect(LeoPluginRenderStyle.color(for: .warning) == LeoPluginRenderStyle.nsColor(for: .tint(.orange)))
        #expect(LeoPluginRenderStyle.color(for: .failure) == LeoPluginRenderStyle.nsColor(for: .tint(.red)))
        #expect(LeoPluginRenderStyle.color(for: .secondary) == .secondaryLabelColor)
    }
}
