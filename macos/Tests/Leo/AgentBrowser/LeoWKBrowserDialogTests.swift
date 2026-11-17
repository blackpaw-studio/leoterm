import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-412 on real WebKit: a page's alert, confirm, prompt and beforeunload
/// dialogs reach the browser's dialog desk, the page hears the answer, and
/// a tab closed under an open dialog settles it (WebKit raises otherwise).
@MainActor
@Suite(.serialized)
struct LeoWKBrowserDialogTests {
    private static let pages = [
        "dialogs": "<title>Dialogs</title><p>Ready</p>",
        "next": "<title>Next</title><p>Next page</p>",
        "leave": """
        <title>Leave</title>
        <button onclick="window.armed = true">Arm</button>
        <script>addEventListener('beforeunload', event => { event.preventDefault(); event.returnValue = '' })</script>
        """,
    ]

    private struct NoDialog: Error {}

    @available(macOS 14, *)
    private func browser() -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LeoWKFixtureServer(Self.pages), forURLScheme: LeoWKFixtureServer.scheme)
        return LeoAgentBrowser(
            key: LeoAgentBrowserKey(host: .local, agent: "alfred"), configuration: configuration, urlMapping: LeoIdentityURLMapping(),
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600))),
            allowsURL: { url in [LeoWKFixtureServer.scheme, "about"].contains(url.scheme ?? "") }
        )
    }

    /// Runs `trigger`, then waits for the next dialog the desk opens. A
    /// dialog that never comes fails after a while instead of hanging.
    @available(macOS 14, *)
    private func nextDialog(_ desk: LeoBrowserDialogDesk, after trigger: () -> Void) async throws -> LeoBrowserDialog {
        let opened = LeoOnce<LeoBrowserDialog>()
        let stop = desk.observe { if case .opened(let dialog) = $0 { opened.resume(with: .success(dialog)) } }
        defer { stop() }
        let giveUp = Task { @MainActor in
            try await Task.sleep(for: .seconds(10))
            opened.resume(with: .failure(NoDialog()))
        }
        defer { giveUp.cancel() }
        trigger()
        return try await opened.value()
    }

    @available(macOS 14, *)
    private func request(_ tool: String, _ args: [String: LeoJSONValue]) -> LeoClientToolRequest {
        LeoClientToolRequest(id: "ctr_\(tool)", agent: "alfred", group: "browser", tool: tool, args: .object(args), timeoutSeconds: 30)
    }

    @available(macOS 14, *)
    @Test func alertConfirmPromptReachTheDeskAndThePageSeesTheAnswer() async throws {
        let browser = browser()
        defer { browser.close() }
        let tab = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("dialogs"))
        let page = try #require(browser.tabs.page(forTab: tab))
        let desk = browser.tabs.dialogs
        var running: Task<String, any Error>?

        let confirm = try await nextDialog(desk) { running = Task { try await page.evaluate("return confirm('Delete report.pdf?')") } }
        #expect(confirm.kind == .confirm)
        #expect(confirm.message == "Delete report.pdf?")
        #expect(confirm.tab == tab)
        #expect(confirm.site == LeoBrowserSite(scheme: LeoWKFixtureServer.scheme, host: "fixture", port: nil))
        _ = desk.answer(inTab: tab, accept: true, by: .user)
        #expect(try await running?.value == "true")

        let alert = try await nextDialog(desk) { running = Task { try await page.evaluate("alert('Saved'); return 'after'") } }
        #expect(alert.kind == .alert)
        _ = desk.answer(inTab: tab, accept: false, by: .agent)
        #expect(try await running?.value == #""after""#)

        let prompt = try await nextDialog(desk) { running = Task { try await page.evaluate("return prompt('Name?', 'Untitled')") } }
        #expect(prompt.kind == .prompt)
        #expect(prompt.defaultText == "Untitled")
        _ = desk.answer(inTab: tab, accept: true, text: "Q3", by: .agent)
        #expect(try await running?.value == #""Q3""#)

        _ = try await nextDialog(desk) { running = Task { try await page.evaluate("return prompt('Name?', 'Untitled')") } }
        _ = desk.answer(inTab: tab, accept: false, by: .user)
        #expect(try await running?.value == "null")
    }

    /// The agent's call returns as soon as its click opens a dialog, and
    /// `browser_dialog` answers it while the page is paused.
    @available(macOS 14, *)
    @Test func anAgentCallThatOpensADialogReturnsAtOnceAndBrowserDialogAnswersIt() async throws {
        let browser = browser()
        defer { browser.close() }
        let tab = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("dialogs"))
        let page = try #require(browser.tabs.page(forTab: tab))

        let opened = await browser.execute(request("browser_eval", ["js": .string("window.answer = confirm('Go on?'); return 1")]))
        guard case .success(let content) = opened, case .text(let text)? = content.first else { Issue.record("expected text, got \(opened)"); return }
        #expect(text.hasPrefix("While this call ran, tab \(tab) opened a JavaScript confirm"))
        #expect(await browser.execute(request("browser_snapshot", [:])).isFailure(code: "dialog_open"))

        #expect(await browser.execute(request("browser_dialog", ["action": .string("dismiss")])) == .success([.text("ok")]))
        #expect(try await page.evaluate("return window.answer") == "false")
    }

    @available(macOS 14, *)
    @Test func leaveDialogReachesTheDeskAfterUserInteraction() async throws {
        let browser = browser()
        defer { browser.close() }
        let tab = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("leave"))
        let page = try #require(browser.tabs.page(forTab: tab) as? LeoWKBrowserPage)
        // beforeunload asks only on a page the user has interacted with;
        // the agent's clicks are real (isTrusted) events.
        let ref = try #require(leoSnapshotRef(try await page.snapshot(), #"button "Arm""#))
        try await page.click(ref: ref)
        #expect(try await page.evaluate("return window.armed === true") == "true")
        let desk = browser.tabs.dialogs

        let stay = try await nextDialog(desk) { page.webView.load(URLRequest(url: LeoWKFixtureServer.url("next"))) }
        #expect(stay.kind == .leave)
        _ = desk.answer(inTab: tab, accept: false, by: .user)
        #expect(try await page.evaluate("return document.title") == #""Leave""#)

        let leave = try await nextDialog(desk) { page.webView.load(URLRequest(url: LeoWKFixtureServer.url("next"))) }
        #expect(leave.kind == .leave)
        _ = desk.answer(inTab: tab, accept: true, by: .agent)
        try await page.waitForText("Next page", timeoutMilliseconds: 5_000)
    }

    @available(macOS 14, *)
    @Test func closingATabWithAPendingDialogResolvesIt() async throws {
        let browser = browser()
        defer { browser.close() }
        let tab = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("dialogs"))
        let page = try #require(browser.tabs.page(forTab: tab))
        let desk = browser.tabs.dialogs
        var running: Task<String, any Error>?
        var events: [LeoBrowserDialogDesk.Event] = []
        let stop = desk.observe { events.append($0) }
        defer { stop() }

        let dialog = try await nextDialog(desk) { running = Task { try await page.evaluate("return confirm('Close?')") } }
        browser.tabs.closeTab(tab)

        #expect(desk.dialogs.isEmpty)
        #expect(events.last == .withdrawn(dialog))
        running?.cancel()
        _ = try? await running?.value
    }

    @available(macOS 14, *)
    @Test func closingTheBrowserResolvesEveryOpenDialog() async throws {
        let browser = browser()
        let tab = try await browser.tabs.openTab(url: LeoWKFixtureServer.url("dialogs"))
        let page = try #require(browser.tabs.page(forTab: tab))
        let desk = browser.tabs.dialogs
        var running: Task<String, any Error>?

        _ = try await nextDialog(desk) { running = Task { try await page.evaluate("return confirm('Quit?')") } }
        browser.close()

        #expect(desk.dialogs.isEmpty)
        running?.cancel()
        _ = try? await running?.value
    }
}

extension LeoClientToolOutcome {
    func isFailure(code: String) -> Bool {
        if case .failure(let error) = self { return error.code == code }
        return false
    }
}
