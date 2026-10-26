import AppKit
import Testing
import LeoKit

@testable import Ghostty

/// The browser toolbar: the control pill draws once per change, not in a
/// loop, and the address bar goes back to showing the page's address after
/// the user submits one.
@MainActor
struct LeoAgentBrowserToolbarTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// Counts the pill's layer updates.
    private final class CountingPill: LeoControlPill {
        private(set) var layerUpdates = 0

        override func updateLayer() {
            layerUpdates += 1
            super.updateLayer()
        }
    }

    private static func window(showing view: NSView) -> NSWindow {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    /// One display pass as the run loop makes it: views marked, then the
    /// transaction committed, which is when layers update.
    private static func displayPass(_ window: NSWindow) {
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// The pill paints its capsule only in display passes -- so in the
    /// window's appearance, not the app's -- and an idle pill doesn't repaint.
    @Test func thePillPaintsInDisplayPassesUnderTheWindowsAppearance() throws {
        let pill = CountingPill()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        pill.frame = NSRect(x: 10, y: 10, width: 140, height: 18)
        container.addSubview(pill)
        let window = Self.window(showing: container)
        let isAppDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance = try #require(NSAppearance(named: isAppDark ? .aqua : .darkAqua))
        window.appearance = appearance
        Self.displayPass(window)
        let before = pill.layerUpdates

        pill.show(LeoAgentBrowserPaneModel(source: FakePaneSource()).pill)
        #expect(pill.layerUpdates == before)
        for _ in 0..<5 { Self.displayPass(window) }

        #expect(pill.layerUpdates == before + 1)
        var capsule: CGColor?
        appearance.performAsCurrentDrawingAppearance { capsule = NSColor.labelColor.withAlphaComponent(0.08).cgColor }
        #expect(pill.layer?.backgroundColor == capsule)
    }

    @Test func submittingAnAddressEndsEditingSoTheBarFollowsThePage() async throws {
        let source = FakePaneSource()
        let pane = LeoAgentBrowserPaneViewController(source: source)
        pane.view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = Self.window(showing: pane.view)
        let field = pane.toolbar.urlField
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "example.com"

        field.sendAction(field.action, to: field.target)
        source.activeRemoteURL = URL(string: "https://example.com/welcome")
        source.changed()
        await drainMainQueue()

        #expect(source.calls == ["navigate https://example.com"])
        #expect(field.currentEditor() == nil)
        #expect(field.stringValue == "https://example.com/welcome")
    }
}
