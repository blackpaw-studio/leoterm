import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// E5: a browser's active page shows in the pane on screen and waits in
/// the parking window otherwise, moving between them without reloading.
/// With several windows showing the same row, the last one shown has it.
@MainActor
@Suite(.serialized)
struct LeoAgentBrowserHostTests {
    /// A window standing in for one showing the row's pane.
    @MainActor private final class PaneWindow {
        let window: NSWindow
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let slot = LeoAgentBrowserSlot(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        init(showing source: any LeoAgentBrowserPaneSource, window: NSWindow? = nil) {
            self.window = window ?? LeoWKTestHost.offscreenWindow(size: CGSize(width: 900, height: 700))
            slot.onVisibilityChange = { [weak slot] isVisible in
                guard let slot else { return }
                if isVisible { source.viewHost.show(source, in: slot) } else { source.viewHost.hide(slot) }
            }
            self.window.contentView?.addSubview(container)
            show()
        }

        func show() { container.addSubview(slot) }
        func leave() { slot.removeFromSuperview() }

        func close() {
            leave()
            window.close()
        }
    }

    private static let counter = """
    <title>Counter</title>
    <script>window.token = Math.random(); window.count = 0;</script>
    """

    @available(macOS 14, *)
    private func browser(host: LeoAgentBrowserHost) -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LeoWKFixtureServer(["counter": Self.counter]), forURLScheme: LeoWKFixtureServer.scheme)
        return LeoAgentBrowser(
            key: LeoAgentBrowserKey(host: .local, agent: "alpha"), configuration: configuration, urlMapping: LeoIdentityURLMapping(),
            input: LeoSyntheticInput(application: LeoWKTestHost.application), viewHost: host,
            allowsURL: { url in [LeoWKFixtureServer.scheme, "about"].contains(url.scheme ?? "") }
        )
    }

    @available(macOS 14, *)
    @Test func aRowSwitchMovesThePageWithoutReloadingIt() async throws {
        let host = LeoAgentBrowserHost()
        let browser = browser(host: host)
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("counter"))
        let page = try #require(browser.tabs.page(forTab: nil))
        let view = try #require(browser.activeView)
        #expect(view.window === host.parking)
        let pane = PaneWindow(showing: browser)
        defer { pane.close() }
        #expect(view.window === pane.window)
        let token = try await page.evaluate("window.count += 1; return window.token")

        pane.leave()
        #expect(view.window === host.parking)
        #expect(try await page.evaluate("window.count += 1; return window.token") == token)

        pane.show()
        #expect(view.window === pane.window)
        #expect(view.superview === pane.slot)
        #expect(try await page.evaluate("return [window.count, window.token]") == "[2,\(token)]")
    }

    @available(macOS 14, *)
    @Test func aHiddenPaneLeavesThePageParked() async throws {
        let host = LeoAgentBrowserHost()
        let browser = browser(host: host)
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("counter"))
        let view = try #require(browser.activeView)
        let pane = PaneWindow(showing: browser)
        defer { pane.close() }

        pane.container.isHidden = true
        #expect(view.window === host.parking)

        pane.container.isHidden = false
        #expect(view.window === pane.window)
    }

    @available(macOS 14, *)
    @Test func switchingTabsShowsTheNewOneAndParksTheOld() async throws {
        let host = LeoAgentBrowserHost()
        let browser = browser(host: host)
        defer { browser.close() }
        let first = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("counter"))
        let firstView = try #require(browser.activeView)
        let pane = PaneWindow(showing: browser)
        defer { pane.close() }

        _ = try await browser.tabs.openTab(url: URL(string: "about:blank")!)
        let secondView = try #require(browser.activeView)
        #expect(secondView.window === pane.window)
        #expect(firstView.window === host.parking)

        browser.tabs.selectTab(first)
        #expect(firstView.window === pane.window)
        #expect(secondView.window === host.parking)
    }

    /// A window that says it is in the Dock.
    private final class MiniaturizedWindow: NSWindow {
        override var isMiniaturized: Bool { true }
    }

    /// B-410: a permission prompt only counts as seen on the slot that has
    /// the page, in a window that is ordered in and not in the Dock.
    /// Occlusion is the system's call; test windows sit off screen, so the
    /// test treats every window as unoccluded.
    @Test func isOnScreenOnlyForWinningSlotInVisibleWindow() {
        let host = LeoAgentBrowserHost(isUnoccluded: { _ in true })
        let source = FakePaneSource(viewHost: host)
        let page = NSView()
        source.activeView = page
        host.adopt(page)
        #expect(!host.isOnScreen(page), "parked")

        let first = PaneWindow(showing: source)
        defer { first.close() }
        #expect(host.isOnScreen(page))
        #expect(host.isInPane(page))

        let second = PaneWindow(showing: source)
        defer { second.close() }
        #expect(host.isOnScreen(page), "the winning slot has it")
        second.window.orderOut(nil)
        #expect(!host.isOnScreen(page), "ordered out")
        #expect(host.isInPane(page), "an ordered-out window still holds the page")
        second.leave()
        #expect(host.isOnScreen(page), "back in the first window")

        let docked = MiniaturizedWindow(
            contentRect: LeoWKTestHost.offscreenFrame(size: CGSize(width: 900, height: 700)), styleMask: .borderless, backing: .buffered, defer: false
        )
        docked.isReleasedWhenClosed = false
        docked.orderBack(nil)
        let third = PaneWindow(showing: source, window: docked)
        defer { third.close() }
        #expect(!host.isOnScreen(page), "miniaturized")
        #expect(first.slot.isShownElsewhere)
    }

    @Test func occlusionCountsAsOffScreen() {
        var unoccluded = true
        let host = LeoAgentBrowserHost(isUnoccluded: { _ in unoccluded })
        let source = FakePaneSource(viewHost: host)
        let page = NSView()
        source.activeView = page
        host.adopt(page)
        let pane = PaneWindow(showing: source)
        defer { pane.close() }
        #expect(host.isOnScreen(page))
        unoccluded = false
        #expect(!host.isOnScreen(page))
    }

    @Test func placementObserversHearShowsHidesAndRefreshes() {
        let host = LeoAgentBrowserHost()
        let source = FakePaneSource(viewHost: host)
        let page = NSView()
        source.activeView = page
        host.adopt(page)
        var count = 0
        let stop = host.observePlacement { count += 1 }
        let pane = PaneWindow(showing: source)
        defer { pane.close() }
        #expect(count == 1)
        host.refresh(source)
        #expect(count == 2)
        pane.leave()
        #expect(count == 3)
        stop()
        pane.show()
        #expect(count == 3)
    }

    @Test func theLastWindowShownHasThePageAndTheOthersSaySo() {
        let source = FakePaneSource()
        let page = NSView()
        source.activeView = page
        source.viewHost.adopt(page)
        let first = PaneWindow(showing: source)
        defer { first.close() }
        #expect(page.window === first.window)

        let second = PaneWindow(showing: source)
        defer { second.close() }

        #expect(page.window === second.window)
        #expect(first.slot.isShownElsewhere)
        #expect(!second.slot.isShownElsewhere)

        second.leave()
        #expect(page.window === first.window)
        #expect(!first.slot.isShownElsewhere)
    }
}
