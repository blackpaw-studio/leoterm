import Foundation
import LeoKit
import Testing
import UIKit
import WebKit

@testable import Leo

/// B-305: the agent browser on iPhone, on real WebKit in the app's window.
/// The agent's input is script events, so what matters is that pages see
/// it as a user's (forms change and submit) and that it never takes control;
/// that a page can't fake the user's input; that a page on the agent
/// machine's localhost is refused with the plain reason; and that dialogs go
/// through the desk. Serialized: each test hosts web views in the window.
@MainActor
@Suite(.serialized)
struct LeoIOSBrowserTests {
    private static let form = """
    <!doctype html><title>Form</title>
    <form id="f"><label for="q">Query</label><input id="q"><button type="button" id="go" onclick="out.textContent='clicked'">Go</button>
    <label for="s">Size</label><select id="s" onchange="out.dataset.size=this.value"><option value="sm">Small</option><option value="lg">Large</option></select></form>
    <p id="out"></p>
    <script>
    document.getElementById('f').addEventListener('submit', e => { e.preventDefault(); out.dataset.submitted = q.value; });
    q.addEventListener('input', () => { out.dataset.inputs = String(Number(out.dataset.inputs || 0) + 1); });
    </script>
    """

    @Test func theAgentsTypingClicksAndPicksChangeThePageLikeAUsers() async throws {
        let host = try BrowserHost(pages: ["form": Self.form])
        defer { host.close() }
        let page = try await host.openPage("form")

        let snapshot = try await page.snapshot()
        try await page.type(ref: try #require(ref(snapshot, "textbox \"Query\"")), text: "red shoes", submit: true)
        try await page.click(ref: try #require(ref(snapshot, "button \"Go\"")))
        let picked = try await page.selectOption(ref: try #require(ref(snapshot, "combobox \"Size\"")), values: ["Large"])

        #expect(try await page.evaluate("out.dataset.submitted") == "\"red shoes\"", "Enter submitted the form with the typed text")
        #expect(try await page.evaluate("Number(out.dataset.inputs) > 0") == "true", "frameworks saw input events")
        #expect(try await page.evaluate("out.textContent") == "\"clicked\"")
        #expect(picked == [LeoBrowserSelectedOption(value: "lg", label: "Large")])
        #expect(host.userInputs == 0, "the agent's input never takes control")
    }

    @Test func aKeyPressReachesTheFocusedField() async throws {
        let host = try BrowserHost(pages: ["form": Self.form])
        defer { host.close() }
        let page = try await host.openPage("form")
        let snapshot = try await page.snapshot()
        try await page.type(ref: try #require(ref(snapshot, "textbox \"Query\"")), text: "ab", submit: false)

        try await page.press(try #require(LeoBrowserKeyCombo("Backspace")))
        try await page.press(try #require(LeoBrowserKeyCombo("c")))

        #expect(try await page.evaluate("q.value") == "\"ac\"")
        #expect(host.userInputs == 0)
    }

    @Test func aPageCannotPostTheUsersInputOnlyLeosWorldCan() async throws {
        let host = try BrowserHost(pages: ["form": Self.form])
        defer { host.close() }
        let page = try await host.openPage("form")
        let post = "webkit.messageHandlers.\(LeoBrowserScripts.userInputHandlerName).postMessage('key'); return 0"

        _ = try? await page.run(post, [:], in: .page)
        _ = try await page.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'a'})), 0")
        #expect(host.userInputs == 0, "a page's own script and synthetic keys don't count")

        _ = try await page.run(post, [:], in: LeoIOSBrowserPage.agentWorld)
        await until { host.userInputs == 1 }
    }

    @Test func thePhoneRefusesTheAgentMachinesLocalhostWithThePlainReason() async throws {
        let host = try BrowserHost(pages: [:])
        defer { host.close() }
        let browser = host.browser(machine: "dionysus")
        defer { browser.close() }

        let outcome = await browser.execute(LeoClientToolRequest(
            id: "ctr_1", agent: "zeus", group: "browser", tool: "browser_navigate",
            args: .object(["url": .string("http://localhost:5173/")]), timeoutSeconds: 30
        ))
        guard case .failure(let error) = outcome else { Issue.record("navigating to localhost succeeded"); return }
        #expect(error.code == "localhost_unreachable")
        #expect(error.message == "This page is on dionysus's localhost, which Leo on iPhone can't reach. Use an address on your network instead.")

        browser.navigate(to: "127.0.0.1:3000")
        await until { browser.refusal?.code == .localhostUnreachable }
        #expect(browser.externalURL == nil)
    }

    @Test func workspaceToolsSayTheyAreUnsupportedHere() async throws {
        let host = try BrowserHost(pages: ["form": Self.form])
        defer { host.close() }
        let browser = host.browser(machine: "dionysus")
        defer { browser.close() }

        let outcome = await browser.execute(LeoClientToolRequest(
            id: "ctr_1", agent: "zeus", group: "browser", tool: "browser_pdf", args: .object([:]), timeoutSeconds: 30
        ))

        guard case .failure(let error) = outcome else { Issue.record("browser_pdf succeeded"); return }
        #expect(error.code == "unsupported")
    }

    @Test func aConfirmWaitsOnTheDeskUntilAnswered() async throws {
        let host = try BrowserHost(pages: ["form": Self.form])
        defer { host.close() }
        let browser = host.browser(machine: "dionysus")
        defer { browser.close() }
        _ = try await browser.tabSet.openTab(url: BrowserHost.url("form"))
        let page = try #require(browser.tabSet.activePage)

        // The page is paused inside confirm() until it's answered, so the
        // call that opened it runs on its own; a watchdog keeps a lost answer
        // from hanging the suite.
        let running = Task { try await page.evaluate("return confirm('Discard?')") }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            running.cancel()
        }
        defer { watchdog.cancel() }
        await until { browser.pendingDialog != nil }
        let prompt = try #require(browser.pendingDialog)
        #expect(prompt.message == "Discard?")
        browser.answerDialog(prompt, accept: true, text: nil)

        #expect(try await running.value == "true")
        #expect(browser.pendingDialog == nil)
    }

    @Test func openingThePaneLeavesTheAgentDriving() async throws {
        let host = try BrowserHost(pages: [:])
        defer { host.close() }
        let browser = host.browser(machine: "dionysus")
        defer { browser.close() }

        browser.openBlankTabIfEmpty()
        await until { browser.activeWebView != nil }

        #expect(browser.control.state == .agent, "the pane's own blank tab isn't the user acting")
    }

    @Test func eachAgentGetsTheStoreTheMacNamesForIt() {
        let configuration = LeoIOSAgentBrowser.configuration(daemonID: "d1", agent: "zeus")

        #expect(configuration.websiteDataStore.identifier == LeoBrowserStoreID.identifier(machineID: "d1", agent: "zeus"))
        #expect(configuration.websiteDataStore.identifier != LeoIOSAgentBrowser.configuration(daemonID: "d1", agent: "hera").websiteDataStore.identifier)
    }

    // MARK: - Helpers

    private func ref(_ snapshot: String, _ prefix: String) -> String? {
        let line = snapshot.split(separator: "\n").first { $0.contains("- \(prefix)") && $0.contains("[ref=") }
        guard let line, let range = line.range(of: #"s\d+e\d+"#, options: .regularExpression) else { return nil }
        return String(line[range])
    }

    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}

/// Fixture pages at `leotest://fixture/<name>`, in a window of their own.
@MainActor private final class BrowserHost {
    let window: UIWindow
    let parking: LeoIOSBrowserParking
    private let configuration: WKWebViewConfiguration
    private(set) var userInputs = 0
    private var pages: [LeoIOSBrowserPage] = []

    init(pages: [String: String]) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.isHidden = false
        let window = window
        parking = LeoIOSBrowserParking { window }
        configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(FixtureSchemeHandler(pages), forURLScheme: "leotest")
    }

    static func url(_ name: String) -> URL { URL(string: "leotest://fixture/\(name)")! }

    func openPage(_ name: String) async throws -> LeoIOSBrowserPage {
        let page = LeoIOSBrowserPage(configuration: configuration, allowsURL: { _ in true })
        page.onUserInput = { [weak self] in self?.userInputs += 1 }
        parking.park(page.webView)
        pages.append(page)
        try await page.load(Self.url(name))
        return page
    }

    func browser(machine: String) -> LeoIOSAgentBrowser {
        let browser = LeoIOSAgentBrowser(
            key: LeoAgentBrowserKey(host: .remote("d1"), agent: "zeus"), machineName: machine,
            configuration: configuration, viewHost: parking,
            allowsURL: { $0.scheme == "leotest" || LeoBrowserURLPolicy.allows($0) }
        )
        return browser
    }

    func close() {
        pages.forEach { $0.webView.removeFromSuperview() }
        window.isHidden = true
    }
}

private final class FixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    private let pages: [String: String]

    init(_ pages: [String: String]) {
        self.pages = pages
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let html = pages[url.lastPathComponent] else {
            return urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        }
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
