import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-410: a page's camera, microphone and location requests ask the human
/// in the pane, never an agent. A request is denied at once when the pane
/// isn't showing its tab; an ask is withdrawn (denied, not remembered) when
/// its page leaves the pane; the user's answer lasts for the tab's life.
@MainActor
@Suite(.serialized)
struct LeoAgentBrowserPermissionTests {
    private static let pages = [
        "call": #"<title>Call</title><button onclick="document.title='clicked'">Join</button><input>"#,
        "next": "<title>Next</title><p>Next page</p>",
    ]
    private nonisolated static let meet = LeoBrowserSite(scheme: "https", host: "meet.example.com", port: 8443)
    private nonisolated static let maps = LeoBrowserSite(scheme: "https", host: "maps.example.com", port: 0)

    /// A window standing in for one showing the browser's pane.
    @MainActor private final class Pane {
        let window = LeoWKTestHost.offscreenWindow(size: CGSize(width: 800, height: 600))
        let slot = LeoAgentBrowserSlot(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        init(showing source: any LeoAgentBrowserPaneSource) {
            slot.onVisibilityChange = { [weak slot] isVisible in
                guard let slot else { return }
                if isVisible { source.viewHost.show(source, in: slot) } else { source.viewHost.hide(slot) }
            }
            show()
        }

        func show() { window.contentView?.addSubview(slot) }
        func hide() { slot.removeFromSuperview() }

        func close() {
            hide()
            window.close()
        }
    }

    /// Every answer one request got, in order: it must get exactly one.
    @MainActor private final class Answers {
        var values: [Bool] = []
    }

    /// Off-screen test windows are never "unoccluded" to the system, so the
    /// host treats every window as uncovered; ordering and the Dock still count.
    @available(macOS 14, *)
    private func browser(agent: String = "alfred") -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LeoWKFixtureServer(Self.pages), forURLScheme: LeoWKFixtureServer.scheme)
        return LeoAgentBrowser(
            key: LeoAgentBrowserKey(host: .local, agent: agent), configuration: configuration, urlMapping: LeoIdentityURLMapping(),
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(
                parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)), isUnoccluded: { _ in true }
            ),
            allowsURL: { url in [LeoWKFixtureServer.scheme, "about"].contains(url.scheme ?? "") }
        )
    }

    @available(macOS 14, *)
    private func webView(_ browser: LeoAgentBrowser, tab: Int? = nil) throws -> WKWebView {
        try #require((browser.tabs.page(forTab: tab) as? LeoWKBrowserPage)?.webView)
    }

    @available(macOS 14, *)
    @discardableResult
    private func ask(
        _ browser: LeoAgentBrowser, _ kind: LeoBrowserPermissionKind = .camera, site: LeoBrowserSite = meet, tab: Int? = nil
    ) throws -> Answers {
        let answers = Answers()
        browser.tabSet.requestPermission(for: try webView(browser, tab: tab), kind: kind, site: site) { answers.values.append($0) }
        return answers
    }

    @available(macOS 14, *)
    private func consoleTexts(_ browser: LeoAgentBrowser, tab: Int? = nil) throws -> [String] {
        try #require(browser.tabs.page(forTab: tab)).consoleMessages(since: 0).entries.map(\.text)
    }

    @available(macOS 14, *)
    private func waiting(_ browser: LeoAgentBrowser) -> [LeoBrowserPermissionRequest?] {
        browser.tabs.tabs.map(\.waitingPermission)
    }

    // MARK: - Hidden or background: denied at once

    @available(macOS 14, *)
    @Test func hiddenPaneDeniesAtOnceAndNotesConsole() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)

        let answers = try ask(browser, .cameraAndMicrophone)

        #expect(answers.values == [false])
        #expect(browser.pendingPermission == nil)
        #expect(waiting(browser) == [nil])
        let denied = LeoBrowserPermissionText.deniedLine(kind: .cameraAndMicrophone, origin: "https://meet.example.com:8443", because: .notShown)
        #expect(try consoleTexts(browser) == [denied])
        #expect(denied.hasPrefix("permission_denied: https://meet.example.com:8443"))
        #expect(denied.contains("the camera and microphone"))
        #expect(denied.contains("wasn't showing this tab"))
    }

    @available(macOS 14, *)
    @Test func backgroundTabIsDenied() async throws {
        let browser = browser()
        defer { browser.close() }
        let background = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        let answers = try ask(browser, .location, site: Self.maps, tab: background)

        #expect(answers.values == [false])
        #expect(browser.pendingPermission == nil)
        #expect(try consoleTexts(browser, tab: background).first?.hasPrefix("permission_denied: https://maps.example.com was denied access to location") == true)
    }

    // MARK: - Shown: the user is asked

    @available(macOS 14, *)
    @Test func shownRequestWaitsNamingAgentAndSite() async throws {
        let browser = browser(agent: "alfred")
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        let answers = try ask(browser, .camera)

        #expect(answers.values.isEmpty)
        let prompt = try #require(browser.pendingPermission)
        #expect(prompt.message == "alfred · meet.example.com:8443 wants to use your camera")
        #expect(waiting(browser) == [LeoBrowserPermissionRequest(kind: .camera, site: Self.meet)])
        #expect(try consoleTexts(browser).isEmpty)
    }

    @available(macOS 14, *)
    @Test func allowIsRememberedForTheTabOnly() async throws {
        let browser = browser()
        defer { browser.close() }
        let first = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        let answers = try ask(browser)
        browser.answerPermission(try #require(browser.pendingPermission), allow: true)
        #expect(answers.values == [true])
        #expect(browser.pendingPermission == nil)
        #expect(waiting(browser) == [nil])

        let again = try ask(browser)
        #expect(again.values == [true], "remembered for this site and kind")
        #expect(try ask(browser, .microphone).values.isEmpty, "another kind asks")

        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let other = try ask(browser)
        #expect(other.values.isEmpty, "a new tab asks again")
        browser.tabs.selectTab(first)
        #expect(other.values == [false], "switching away withdraws it")
    }

    @available(macOS 14, *)
    @Test func dontAllowIsRememberedAndSaysSo() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        let answers = try ask(browser, .location, site: Self.maps)
        browser.answerPermission(try #require(browser.pendingPermission), allow: false)
        let again = try ask(browser, .location, site: Self.maps)

        #expect(answers.values == [false])
        #expect(again.values == [false])
        #expect(try consoleTexts(browser) == [
            LeoBrowserPermissionText.deniedLine(kind: .location, origin: "https://maps.example.com", because: .user),
            LeoBrowserPermissionText.deniedLine(kind: .location, origin: "https://maps.example.com", because: .remembered),
        ])
    }

    @available(macOS 14, *)
    @Test func secondRequestQueues() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        let camera = try ask(browser, .camera)
        let cameraAgain = try ask(browser, .camera)
        let location = try ask(browser, .location, site: Self.maps)
        #expect(browser.pendingPermission?.request.kind == .camera)

        browser.answerPermission(try #require(browser.pendingPermission), allow: true)
        #expect(camera.values == [true])
        #expect(cameraAgain.values == [true], "the same request is answered by the same answer")
        #expect(location.values.isEmpty)
        #expect(browser.pendingPermission?.request == LeoBrowserPermissionRequest(kind: .location, site: Self.maps))
    }

    @available(macOS 14, *)
    @Test func aStaleAnswerIsIgnored() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        let first = try ask(browser, .camera)
        let shown = try #require(browser.pendingPermission)
        pane.hide()
        pane.show()
        let second = try ask(browser, .camera)
        browser.answerPermission(shown, allow: true)

        #expect(first.values == [false])
        #expect(second.values.isEmpty, "an answer to the withdrawn ask never answers the new one")
        #expect(browser.pendingPermission != nil)
    }

    // MARK: - Withdrawal

    @available(macOS 14, *)
    @Test func pendingIsDeniedOnceWhenTabClosesSwitchesNavigatesOrPaneHides() async throws {
        let browser = browser()
        defer { browser.close() }
        let first = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("call"))
        let pane = Pane(showing: browser)
        defer { pane.close() }

        // The pane hides.
        let hidden = try ask(browser)
        pane.hide()
        #expect(hidden.values == [false])
        #expect(waiting(browser) == [nil])
        pane.show()

        // Another tab becomes active.
        let switched = try ask(browser)
        let second = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        #expect(switched.values == [false])
        browser.tabs.selectTab(first)

        // The page navigates.
        let navigated = try ask(browser)
        let page = try #require(browser.tabs.page(forTab: first))
        try await page.load(LeoWKFixtureServer.url("next"))
        #expect(navigated.values == [false])

        // The page's content process stops.
        let stopped = try ask(browser)
        try #require(page as? LeoWKBrowserPage).webViewWebContentProcessDidTerminate(try webView(browser))
        #expect(stopped.values == [false])

        // None of those was an answer: the next request still asks.
        let fresh = try ask(browser)
        #expect(fresh.values.isEmpty)

        // The tab closes.
        browser.tabs.closeTab(first)
        #expect(fresh.values == [false])

        // The browser closes.
        browser.tabs.selectTab(second)
        let last = try ask(browser)
        browser.close()
        #expect(last.values == [false])
        #expect([hidden, switched, navigated, stopped, fresh, last].allSatisfy { $0.values.count == 1 })
    }

    @available(macOS 14, *)
    @Test func withdrawalSaysWhyInTheConsole() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        try ask(browser)
        pane.hide()

        #expect(try consoleTexts(browser) == [
            LeoBrowserPermissionText.deniedLine(kind: .camera, origin: "https://meet.example.com:8443", because: .withdrawn(.paneHidden)),
        ])
    }

    @available(macOS 14, *)
    @Test func coveringOrOrderingOutTheWindowKeepsTheAsk() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        let answers = try ask(browser)
        pane.window.orderOut(nil)
        browser.viewHost.refresh(browser)

        #expect(answers.values.isEmpty)
        #expect(browser.pendingPermission != nil)
    }

    // MARK: - Agents never answer

    @available(macOS 14, *)
    @Test func agentActionsNeverAnswer() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("call"))
        let pane = Pane(showing: browser)
        defer { pane.close() }
        let answers = try ask(browser)
        let page = try #require(browser.tabs.page(forTab: nil))
        let button = try #require(leoSnapshotRef(try await page.snapshot(), #"button "Join""#))

        for (tool, args) in [
            ("browser_click", ["ref": LeoJSONValue.string(button)]),
            ("browser_press", ["key": .string("Enter")]),
            ("browser_eval", ["js": .string("return 1")]),
        ] {
            let outcome = await browser.execute(LeoClientToolRequest(
                id: "ctr_\(tool)", agent: "alfred", group: "browser", tool: tool, args: .object(args), timeoutSeconds: 30
            ))
            guard case .success = outcome else { Issue.record("\(tool) failed: \(outcome)"); continue }
        }

        #expect(answers.values.isEmpty)
        #expect(browser.pendingPermission != nil)
        #expect(waiting(browser).first??.kind == .camera)
    }

    @available(macOS 14, *)
    @Test func answeringDoesNotTakeControl() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }

        try ask(browser)
        browser.answerPermission(try #require(browser.pendingPermission), allow: false)

        #expect(browser.control.state.allowsAgentActions)
    }

    @available(macOS 14, *)
    @Test func observersHearAnAskArriveAndGo() async throws {
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let pane = Pane(showing: browser)
        defer { pane.close() }
        var seen: [Bool] = []
        let stop = browser.observe { seen.append(browser.pendingPermission != nil) }
        defer { stop() }

        try ask(browser)
        browser.answerPermission(try #require(browser.pendingPermission), allow: false)

        #expect(seen.first == true)
        #expect(seen.last == false)
    }
}
