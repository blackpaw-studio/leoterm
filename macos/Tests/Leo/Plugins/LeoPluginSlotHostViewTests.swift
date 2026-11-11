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

    // MARK: Pushed form sizing

    private func pushedForm(title: String) -> [LeoPluginNode] {
        let fields: [LeoPluginNode.Field] = (0..<6).map { LeoPluginNode.Field(id: "f\($0)", type: .text, label: "Field \($0)") }
            + [LeoPluginNode.Field(id: "go", type: .submit, label: "Create Pull Request")]
        return [.form(.init(id: "pr", title: title, fields: fields))]
    }

    @Test func aLongFormHeadingWrapsInsideThePaneAndNeverWidensIt() {
        let title = "Create PR · blackpaw-studio/leoterm-with-a-very-long-name@feat/a-very-long-branch-name-that-keeps-going-and-going"
        surface.content = .nodes(pushedForm(title: title), isPushed: true)
        let host = makeHost()
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 280)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width <= 500)
        func widest(_ view: NSView) -> CGFloat { ([view.frame.maxX] + view.subviews.map(widest)).max() ?? 0 }
        #expect(widest(host) <= 500.5)
    }

    @Test func aTallFormReportsItsContentHeightSoThePaneCanGrowToFit() {
        surface.content = .nodes(pushedForm(title: "Create PR"), isPushed: true)
        let host = makeHost()
        var reported: CGFloat?
        host.onPreferredHeightChange = { reported = $0 }
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 280)
        host.layoutSubtreeIfNeeded()

        #expect((reported ?? 0) > 280)
    }

    @Test func paletteHeightGrowsToContentWithinTheBounds() {
        #expect(LeoPluginPaletteLayout.height(forContent: nil) == 280)
        #expect(LeoPluginPaletteLayout.height(forContent: 100) == 280)
        #expect(LeoPluginPaletteLayout.height(forContent: 400.2) == 401)
        #expect(LeoPluginPaletteLayout.height(forContent: 5000) == 520)
    }
}
