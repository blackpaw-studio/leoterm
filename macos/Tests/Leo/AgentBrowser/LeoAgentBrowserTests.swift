import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// C5: one agent's browser on WebKit. Links that open a window land as
/// tabs (up to the cap), the agent's data store is the same for the same
/// machine and agent every time, and stopping the agent closes the browser
/// but keeps the store.
@MainActor
@Suite(.serialized, .enabled(if: LeoWKTestHost.hasWindowServer, "needs a window-server session"))
struct LeoAgentBrowserTests {
    private static let pages = [
        "links": """
        <title>Links</title>
        <a href="other" target="_blank">Open other</a>
        """,
        "other": "<title>Other</title><p>Elsewhere</p>",
    ]

    private nonisolated static let key = LeoAgentBrowserKey(host: .remote("dionysus"), agent: "alpha")

    @available(macOS 14, *)
    private func fixtureBrowser(key: LeoAgentBrowserKey = Self.key) -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LeoWKFixtureServer(Self.pages), forURLScheme: LeoWKFixtureServer.scheme)
        return LeoAgentBrowser(
            key: key, configuration: configuration, urlMapping: LeoIdentityURLMapping(),
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600))),
            allowsURL: { url in [LeoWKFixtureServer.scheme, "about"].contains(url.scheme ?? "") }
        )
    }

    @available(macOS 14, *)
    private func click(_ name: String, in browser: LeoAgentBrowser) async throws -> LeoClientToolOutcome {
        let page = try #require(browser.tabs.page(forTab: nil))
        let ref = try #require(leoSnapshotRef(try await page.snapshot(), name))
        return await browser.execute(LeoClientToolRequest(
            id: "ctr_click", agent: Self.key.agent, group: "browser", tool: "browser_click",
            args: .object(["ref": .string(ref)]), timeoutSeconds: 30
        ))
    }

    /// The page asks for a new window after the click returns: round-trips
    /// `page`'s content process until `condition` holds, as the page tests do.
    private func settle(_ page: any LeoBrowserPage, until condition: () -> Bool) async throws {
        for _ in 0..<50 where !condition() { _ = try await page.evaluate("return 0") }
    }

    @available(macOS 14, *)
    @Test func aBlankTargetLinkLandsAsANewActiveTab() async throws {
        let browser = fixtureBrowser()
        defer { browser.close() }
        let first = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("links"))
        let opener = try #require(browser.tabs.page(forTab: first))

        #expect(try await click(#"link "Open other""#, in: browser) == .success([.text("ok")]))
        try await settle(opener) { browser.tabs.tabs.count > 1 }

        let tabs = browser.tabs.tabs
        #expect(tabs.count == 2)
        let opened = try #require(tabs.last)
        #expect(opened.id != first)
        #expect(opened.isActive)
        try await browser.tabs.page(forTab: opened.id)?.waitForText("Elsewhere", timeoutMilliseconds: 5_000)
        #expect(browser.activeView === (browser.tabs.page(forTab: opened.id) as? LeoWKBrowserPage)?.webView)
    }

    @available(macOS 14, *)
    @Test func aPopupPastTheTabCapIsRefusedWithTabLimit() async throws {
        let browser = fixtureBrowser()
        defer { browser.close() }
        for _ in 1..<LeoBrowserLimits.maximumTabs { _ = try await browser.tabs.openTab(url: URL(string: "about:blank")!) }
        let opener = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("links"))

        let page = try #require(browser.tabs.page(forTab: opener))

        #expect(try await click(#"link "Open other""#, in: browser) == .success([.text("ok")]))
        try await settle(page) { !page.consoleMessages(since: 0).entries.isEmpty }

        #expect(browser.tabs.tabs.count == LeoBrowserLimits.maximumTabs)
        let console = page.consoleMessages(since: 0)
        #expect(console.entries.contains { $0.level == "error" && $0.text.hasPrefix("tab_limit:") })
    }

    @available(macOS 14, *)
    @Test func everyTabsViewSitsInAWindowAndClosingATabActivatesAnother() async throws {
        let browser = fixtureBrowser()
        defer { browser.close() }
        let first = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("other"))
        let second = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("links"))
        let firstView = try #require((browser.tabs.page(forTab: first) as? LeoWKBrowserPage)?.webView)
        let secondView = try #require((browser.tabs.page(forTab: second) as? LeoWKBrowserPage)?.webView)
        #expect(firstView.window != nil)
        #expect(secondView.window != nil)

        browser.tabs.closeTab(second)

        #expect(secondView.window == nil)
        #expect(browser.tabs.tabs.map(\.id) == [first])
        #expect(browser.tabs.tabs.first?.isActive == true)
        #expect(browser.activeRemoteURL == LeoWKFixtureServer.url("other"))
    }

    @available(macOS 14, *)
    @Test func theUsersInputInAPageTakesControl() async throws {
        let browser = fixtureBrowser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("other"))
        let view = try #require(browser.activeView as? LeoAgentWebView)

        view.onUserInput?()

        #expect(browser.control.state == .user)
    }

    @available(macOS 14, *)
    @Test func theSameMachineAndAgentGetTheSameStore() async {
        let machineID = "test-\(UUID().uuidString)"
        let factory = LeoAgentBrowserFactory(
            machineID: { _ in machineID }, urlMapping: { _ in LeoIdentityURLMapping() },
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)))
        )

        let one = factory.make(Self.key)
        let again = factory.make(Self.key)
        let other = factory.make(LeoAgentBrowserKey(host: Self.key.host, agent: "beta"))

        #expect(one.dataStore.identifier == LeoBrowserStoreID.identifier(machineID: machineID, agent: "alpha"))
        #expect(one.dataStore.identifier == again.dataStore.identifier)
        #expect(one.dataStore.identifier != other.dataStore.identifier)
        let stores = Set([one, again, other].compactMap(\.dataStore.identifier))
        [one, again, other].forEach { $0.close() }
        for store in stores { try? await WKWebsiteDataStore.remove(forIdentifier: store) }
    }

    @available(macOS 14, *)
    @Test func anAgentStoppingClosesItsBrowserAndKeepsItsStore() async throws {
        let machineID = "test-\(UUID().uuidString)"
        let host = LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)))
        let factory = LeoAgentBrowserFactory(
            machineID: { _ in machineID }, urlMapping: { _ in LeoIdentityURLMapping() },
            input: LeoSyntheticInput(application: LeoWKTestHost.application), viewHost: host
        )
        let browsers = LeoAgentBrowsers(makeBrowser: { factory.make($0) })
        var changes: [LeoAgentBrowserPresenceChange] = []
        let stop = browsers.observe { changes.append($0) }
        defer { stop() }
        let store = LeoBrowserStoreID.identifier(machineID: machineID, agent: Self.key.agent)
        let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "kept", .domain: "example.com", .path: "/", .expires: Date.distantFuture]))

        let opened = try #require(browsers.openBrowser(for: Self.key) as? LeoAgentBrowser)
        await opened.dataStore.httpCookieStore.setCookie(cookie)
        let view = try #require(opened.activeView)
        browsers.agentStopped(Self.key)

        #expect(changes == [.opened(Self.key), .closed(Self.key)])
        #expect(browsers.keys.isEmpty)
        #expect(view.window == nil)
        let reopened = try #require(browsers.openBrowser(for: Self.key) as? LeoAgentBrowser)
        #expect(reopened.dataStore.identifier == store)
        let cookies = await reopened.dataStore.httpCookieStore.allCookies()
        #expect(cookies.contains { $0.name == "session" && $0.value == "kept" })
        browsers.closeBrowser(for: Self.key)
        try? await WKWebsiteDataStore.remove(forIdentifier: store)
    }
}
