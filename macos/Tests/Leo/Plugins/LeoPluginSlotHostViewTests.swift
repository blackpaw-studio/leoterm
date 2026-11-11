import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// The one slot host (pane and palette alike): Loading, the tree, Error with a
/// Retry that goes to the surface, and visibility reported to the surface only.
@MainActor
struct LeoPluginSlotHostViewTests {
    private let surface = FakePluginPaneHost()
    private let key = pluginViewRef().slotKey

    private func makeHost() -> LeoPluginSlotHostView { LeoPluginSlotHostView(key: key, surface: surface) }

    private func buttons(titled title: String, in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, button.title == title { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    @Test func showsLoadingThenTheTreeAsTheSurfaceChanges() {
        let host = makeHost()
        #expect(host.content == .loading)

        let node = LeoPluginNode.emptyState(.init(title: "Done"))
        surface.content = .nodes([node], isPushed: false)
        host.refresh()
        #expect(host.content == .nodes([node], isPushed: false))
    }

    @Test func retryOnAnErrorGoesToTheSurfaceAndIsNotAPluginCallback() throws {
        surface.content = .error("boom")
        let host = makeHost()
        let retry = try #require(buttons(titled: "Retry", in: host).first)

        retry.performClick(nil)

        #expect(surface.retried == [key])
        #expect(surface.performed.isEmpty)
    }

    @Test func aNoticeOffersNoRetry() {
        surface.content = .notice("This plugin is no longer available.")
        #expect(buttons(titled: "Retry", in: makeHost()).isEmpty)
    }

    @Test func visibilityGoesToTheSurfaceWhenTheHostEntersAndLeavesAWindow() {
        let host = makeHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container

        container.addSubview(host)
        #expect(surface.visibility[key] == true)

        container.isHidden = true
        #expect(surface.visibility[key] == false)
        container.isHidden = false
        #expect(surface.visibility[key] == true)

        host.removeFromSuperview()
        #expect(surface.visibility[key] == false)
        window.close()
    }
}
