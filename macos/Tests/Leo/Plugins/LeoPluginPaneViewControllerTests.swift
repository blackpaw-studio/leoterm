import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// The plugin view's pane follows the slot: Loading, the tree, Error with a
/// Retry that re-sends the event, a Back bar over a pushed view.
@MainActor
struct LeoPluginPaneViewControllerTests {
    private let host = FakePluginPaneHost()
    private let ref = pluginViewRef()

    private func makePane() -> LeoPluginPaneViewController {
        let pane = LeoPluginPaneViewController(ref: ref, host: host)
        _ = pane.view
        return pane
    }

    private func buttons(titled title: String, in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, button.title == title { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private let emptyNode = LeoPluginNode.emptyState(.init(title: "Nothing yet"))

    @Test
    func startsOnLoadingUntilThePluginRenders() {
        let pane = makePane()
        #expect(pane.shownContent == .loading)
        #expect(!pane.isBackBarVisible)
    }

    @Test
    func aRenderedTreeReplacesLoading() async {
        let pane = makePane()
        host.content = .nodes([emptyNode], isPushed: false)
        host.changed()

        #expect(await pluginTurnsUntil { pane.shownContent == .nodes([emptyNode], isPushed: false) })
    }

    @Test
    func retryOnAnErrorReSendsTheEventAndIsNotAPluginCallback() throws {
        let pane = makePane()
        host.content = .error("boom")
        pane.refresh()
        let retry = try #require(buttons(titled: "Retry", in: pane.view).first)

        retry.performClick(nil)

        #expect(host.retried == [ref])
        #expect(host.performed.isEmpty)
    }

    @Test
    func aPushedViewShowsBackAndBackPopsIt() throws {
        let pane = makePane()
        host.content = .nodes([emptyNode], isPushed: true)
        pane.refresh()
        #expect(pane.isBackBarVisible)
        let back = try #require(buttons(titled: "Back", in: pane.view).first)

        back.performClick(nil)

        #expect(host.popped == [ref])
    }

    @Test
    func backGoesAwayWhenThePushedViewDoes() {
        let pane = makePane()
        host.content = .nodes([emptyNode], isPushed: true)
        pane.refresh()
        host.content = .nodes([emptyNode], isPushed: false)
        pane.refresh()

        #expect(!pane.isBackBarVisible)
    }

    @Test
    func aNoticeShowsForAPluginThatIsOffAndOffersNoRetry() {
        let pane = makePane()
        host.content = .notice("This plugin is no longer available.")
        pane.refresh()

        #expect(buttons(titled: "Retry", in: pane.view).isEmpty)
    }

    @Test
    func theHostHearsWhenTheViewIsOnScreenAndWhenItIsNot() {
        let pane = makePane()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        #expect(host.visibility[ref] == nil)

        container.addSubview(pane.view)
        #expect(host.visibility[ref] == true)

        pane.view.removeFromSuperview()
        #expect(host.visibility[ref] == false)
        window.close()
    }
}
