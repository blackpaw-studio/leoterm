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
@Suite(.serialized)
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
    private func fixtureBrowser(key: LeoAgentBrowserKey = Self.key, server: LeoWKFixtureServer? = nil) -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = LeoBrowserUserAgent.applicationName()
        configuration.setURLSchemeHandler(server ?? LeoWKFixtureServer(Self.pages), forURLScheme: LeoWKFixtureServer.scheme)
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

    /// B-385: chase.com sends a user agent with no `Version/x Safari/…` tail
    /// to its "unsupported browser" page.
    @available(macOS 14, *)
    @Test func aFactoryBrowserSendsASafariVersionedUserAgent() async throws {
        let machineID = "test-\(UUID().uuidString)"
        let factory = LeoAgentBrowserFactory(
            machineID: { _ in machineID }, urlMapping: { _ in LeoIdentityURLMapping() },
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)))
        )
        let browser = factory.make(Self.key)
        defer { browser.close() }
        let tab = try await browser.tabs.openTab(url: URL(string: "about:blank")!)
        let page = try #require(browser.tabs.page(forTab: tab))

        let userAgent = try await page.evaluate("return navigator.userAgent")

        #expect(userAgent.contains(LeoBrowserUserAgent.applicationName()))
        #expect(userAgent.range(of: #"Version/\d+\.\d+ Safari/605\.1\.15"?$"#, options: .regularExpression) != nil)
        try? await WKWebsiteDataStore.remove(forIdentifier: LeoBrowserStoreID.identifier(machineID: machineID, agent: Self.key.agent))
    }

    // MARK: - B-386: per-tab user agent override

    @available(macOS 14, *)
    private func call(_ browser: LeoAgentBrowser, _ tool: String, _ args: [String: LeoJSONValue]) async -> LeoClientToolOutcome {
        await browser.execute(LeoClientToolRequest(
            id: "ctr_ua", agent: Self.key.agent, group: "browser", tool: tool, args: .object(args), timeoutSeconds: 30
        ))
    }

    /// The new tab's id from a `browser_tab_new` result. The executor only
    /// allows http(s) and about:blank, so fixture-scheme loads go through the
    /// tab API instead.
    @available(macOS 14, *)
    private func openedTab(_ outcome: LeoClientToolOutcome) throws -> Int {
        guard case .success(let content) = outcome, case .text(let text)? = content.first,
              let tab = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Int])?["tab"]
        else { throw LeoBrowserError.invalidArgs("not a tab_new result: \(outcome)") }
        return tab
    }

    @available(macOS 14, *)
    private func pageFor(_ browser: LeoAgentBrowser, _ tab: Int) throws -> any LeoBrowserPage {
        try #require(browser.tabs.page(forTab: tab))
    }

    @available(macOS 14, *)
    private func userAgent(_ browser: LeoAgentBrowser, tab: Int) async throws -> String {
        let page = try #require(browser.tabs.page(forTab: tab))
        let text = try await page.evaluate("return navigator.userAgent")
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        return try #require(decoded as? String)
    }

    @available(macOS 14, *)
    @Test func aTabNewUserAgentReachesThePageAndTheRequest() async throws {
        let server = LeoWKFixtureServer(Self.pages)
        let browser = fixtureBrowser(server: server)
        defer { browser.close() }

        let tab = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("other"), userAgent: "Bot/1.0 (test)")

        #expect(server.userAgents == ["Bot/1.0 (test)"])
        #expect(try await userAgent(browser, tab: tab) == "Bot/1.0 (test)")
    }

    @available(macOS 14, *)
    @Test func settingAUserAgentOnATabAppliesToTheNextRequestAndClearingRestoresTheSafariDefault() async throws {
        let server = LeoWKFixtureServer(Self.pages)
        let browser = fixtureBrowser(server: server)
        defer { browser.close() }
        let tab = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("other"), userAgent: nil)
        let defaultHeader = try #require(server.userAgents.last ?? nil)
        #expect(defaultHeader.contains(LeoBrowserUserAgent.applicationName()))

        #expect(await call(browser, "browser_user_agent", ["user_agent": .string("Bot/2.0"), "tab": .int(tab)]) == .success([.text("ok")]))
        try await pageFor(browser, tab).load(LeoWKFixtureServer.url("links"))
        #expect(server.userAgents.last == "Bot/2.0")
        #expect(try await userAgent(browser, tab: tab) == "Bot/2.0")

        #expect(await call(browser, "browser_user_agent", ["user_agent": .string(""), "tab": .int(tab)]) == .success([.text("ok")]))
        try await pageFor(browser, tab).load(LeoWKFixtureServer.url("other"))
        #expect(server.userAgents.last == defaultHeader)
        #expect(try await userAgent(browser, tab: tab) == defaultHeader)
    }

    /// The factory's browser carries `applicationNameForUserAgent`; a cleared
    /// override must fall back to it, not to a bare WebKit user agent.
    @available(macOS 14, *)
    @Test func clearingTheOverrideOnAFactoryBrowserRestoresTheSafariVersionedDefault() async throws {
        let machineID = "test-\(UUID().uuidString)"
        let factory = LeoAgentBrowserFactory(
            machineID: { _ in machineID }, urlMapping: { _ in LeoIdentityURLMapping() },
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)))
        )
        let browser = factory.make(Self.key)
        defer { browser.close() }
        let tab = try openedTab(await call(browser, "browser_tab_new", ["url": .string("about:blank"), "user_agent": .string("Bot/4.0")]))
        #expect(try await userAgent(browser, tab: tab) == "Bot/4.0")

        _ = await call(browser, "browser_user_agent", ["user_agent": .string(""), "tab": .int(tab)])
        _ = await call(browser, "browser_navigate", ["url": .string("about:blank?again"), "tab": .int(tab)])

        #expect(try await userAgent(browser, tab: tab).contains(LeoBrowserUserAgent.applicationName()))
        try? await WKWebsiteDataStore.remove(forIdentifier: LeoBrowserStoreID.identifier(machineID: machineID, agent: Self.key.agent))
    }

    @available(macOS 14, *)
    @Test func anOverrideLastsForItsTabOnly() async throws {
        let server = LeoWKFixtureServer(Self.pages)
        let browser = fixtureBrowser(server: server)
        defer { browser.close() }
        let overridden = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("other"), userAgent: "Bot/5.0")
        let untouched = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("other"), userAgent: nil)
        let defaultHeader = try #require(server.userAgents.last ?? nil)

        _ = await call(browser, "browser_reload", ["tab": .int(untouched)])
        #expect(server.userAgents.last == defaultHeader)
        #expect(try await userAgent(browser, tab: untouched) == defaultHeader)
        #expect(try await userAgent(browser, tab: overridden) == "Bot/5.0")

        _ = await call(browser, "browser_tab_close", ["tab": .int(overridden)])
        let later = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("other"), userAgent: nil)
        #expect(server.userAgents.last == defaultHeader)
        #expect(try await userAgent(browser, tab: later) == defaultHeader)
    }

    @available(macOS 14, *)
    @Test func aPopupInheritsItsOpenersUserAgentOverride() async throws {
        let browser = fixtureBrowser()
        defer { browser.close() }
        let first = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("links"), userAgent: "Bot/3.0")
        let opener = try #require(browser.tabs.page(forTab: first))

        #expect(try await click(#"link "Open other""#, in: browser) == .success([.text("ok")]))
        try await settle(opener) { browser.tabs.tabs.count > 1 }

        let opened = try #require(browser.tabs.tabs.last)
        try await browser.tabs.page(forTab: opened.id)?.waitForText("Elsewhere", timeoutMilliseconds: 5_000)
        #expect(try await userAgent(browser, tab: opened.id) == "Bot/3.0")
    }

    /// A popup from a tab with no override (or a cleared one) keeps the
    /// Safari-versioned default; an empty `customUserAgent` must not leak
    /// into it as an empty override.
    @available(macOS 14, *)
    @Test func aPopupFromATabWithoutAnOverrideKeepsTheSafariDefault() async throws {
        let browser = fixtureBrowser()
        defer { browser.close() }
        let first = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("links"), userAgent: "Bot/6.0")
        let opener = try #require(browser.tabs.page(forTab: first))
        opener.setUserAgent("")

        #expect(try await click(#"link "Open other""#, in: browser) == .success([.text("ok")]))
        try await settle(opener) { browser.tabs.tabs.count > 1 }

        let opened = try #require(browser.tabs.tabs.last)
        try await browser.tabs.page(forTab: opened.id)?.waitForText("Elsewhere", timeoutMilliseconds: 5_000)
        #expect(try await userAgent(browser, tab: opened.id).contains(LeoBrowserUserAgent.applicationName()))
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
