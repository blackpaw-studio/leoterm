import AppKit
import Testing
import LeoKit

@testable import Ghostty

/// The browser toolbar: the address bar goes back to showing the page's
/// address after the user submits one.
@MainActor
struct LeoAgentBrowserToolbarTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private static func window(showing view: NSView) -> NSWindow {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
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
