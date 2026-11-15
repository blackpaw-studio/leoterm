import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// The app side of slot 2: the allowlist only names symbols this macOS can
/// draw, and the semantic colours map through the sidebar's own tints.
@MainActor
struct LeoPluginAccessoryPresentationTests {
    @Test(arguments: LeoPluginSymbolAllowlist.names.sorted())
    func everyAllowlistedSymbolExists(_ name: String) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not an SF Symbol here")
    }

    @Test
    func semanticColoursUseTheSidebarsTints() {
        #expect(LeoPluginRenderStyle.ink(for: .success) == .tint(.green))
        #expect(LeoPluginRenderStyle.ink(for: .warning) == .tint(.orange))
        #expect(LeoPluginRenderStyle.ink(for: .failure) == .tint(.red))
        #expect(LeoPluginRenderStyle.ink(for: .running) == .tint(.blue))
        #expect(LeoPluginRenderStyle.ink(for: .neutral) == .secondary)
    }
}
