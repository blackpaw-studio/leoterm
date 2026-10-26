import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// A browser with no WebKit behind it, for the registry's own behaviour.
@MainActor final class FakeBrowserModel: LeoAgentBrowserModel {
    let fakeTabs = FakeBrowserTabs()
    let control = LeoBrowserControlModel()
    let viewHost = LeoAgentBrowserHost()
    var tabs: any LeoBrowserTabs { fakeTabs }
    var activeView: NSView?
    var activeRemoteURL: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    private(set) var executed: [String] = []
    private(set) var blankTabsOpened = 0
    private(set) var isClosed = false

    func goBack() {}
    func goForward() {}
    func reload() {}
    func navigate(to url: URL) {}
    func openBlankTab() {}
    func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void { {} }

    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome {
        executed.append(request.id)
        return .success([.text("ok")])
    }

    func openBlankTabIfEmpty() { blankTabsOpened += 1 }
    func close() { isClosed = true }
}

/// C5: the app's agent browsers, one per (machine, agent): made on the
/// first request or Open Browser, closed when the agent stops or the user
/// closes it.
@MainActor
struct LeoAgentBrowsersTests {
    private static let dionysus = LeoHostID.remote("dionysus")

    private final class Made {
        var browsers: [LeoAgentBrowserKey: FakeBrowserModel] = [:]
        var closed: [LeoAgentBrowserKey] = []
    }

    private func registry(_ made: Made, canMake: Bool = true) -> LeoAgentBrowsers {
        LeoAgentBrowsers(
            makeBrowser: { key in
                guard canMake else { return nil }
                let browser = FakeBrowserModel()
                made.browsers[key] = browser
                return browser
            },
            onClosed: { made.closed.append($0) }
        )
    }

    private static func request(_ id: String, agent: String) -> LeoClientToolRequest {
        LeoClientToolRequest(id: id, agent: agent, group: "browser", tool: "browser_tabs", args: .object([:]), timeoutSeconds: 30)
    }

    @Test func theFirstRequestMakesTheBrowserAndLaterOnesReuseIt() async throws {
        let made = Made()
        let browsers = registry(made)
        var changes: [LeoAgentBrowserPresenceChange] = []
        let stop = browsers.observe { changes.append($0) }
        defer { stop() }
        let key = LeoAgentBrowserKey(host: Self.dionysus, agent: "alpha")

        #expect(await browsers.execute(Self.request("ctr_1", agent: "alpha"), on: Self.dionysus) == .success([.text("ok")]))
        #expect(await browsers.execute(Self.request("ctr_2", agent: "alpha"), on: Self.dionysus) == .success([.text("ok")]))

        #expect(made.browsers.count == 1)
        #expect(try #require(made.browsers[key]).executed == ["ctr_1", "ctr_2"])
        #expect(changes == [.opened(key)])
        #expect(browsers.keys == [key])
    }

    @Test func withoutABrowserTheRequestFails() async {
        let made = Made()
        let browsers = registry(made, canMake: false)

        let outcome = await browsers.execute(Self.request("ctr_1", agent: "alpha"), on: Self.dionysus)

        guard case .failure(let error) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(error.code == "navigation_failed")
        #expect(browsers.keys.isEmpty)
    }

    @Test func openBrowserMakesOneOnABlankTabAndReopensTheSame() throws {
        let made = Made()
        let browsers = registry(made)
        let key = LeoAgentBrowserKey(host: .local, agent: "alpha")

        let first = try #require(browsers.openBrowser(for: key))
        let second = try #require(browsers.openBrowser(for: key))

        #expect(first === second)
        #expect(made.browsers[key]?.blankTabsOpened == 2)
        #expect(browsers.keys == [key])
    }

    @Test func closingTellsTheBrowserAndReportsItOnce() throws {
        let made = Made()
        let browsers = registry(made)
        let key = LeoAgentBrowserKey(host: .local, agent: "alpha")
        _ = browsers.openBrowser(for: key)
        var changes: [LeoAgentBrowserPresenceChange] = []
        let stop = browsers.observe { changes.append($0) }
        defer { stop() }

        browsers.closeBrowser(for: key)
        browsers.closeBrowser(for: key)

        #expect(made.browsers[key]?.isClosed == true)
        #expect(changes == [.closed(key)])
        #expect(made.closed == [key])
        #expect(browsers.browser(for: key) == nil)
    }

    @Test func aListingClosesTheBrowsersOfAgentsThatStoppedOrWent() {
        let made = Made()
        let browsers = registry(made)
        let keys = ["alpha", "beta", "gamma", "restoring", "dispatch:d1", "dispatch:d2"].map { LeoAgentBrowserKey(host: Self.dionysus, agent: $0) }
        let elsewhere = LeoAgentBrowserKey(host: .local, agent: "beta")
        (keys + [elsewhere]).forEach { _ = browsers.openBrowser(for: $0) }

        browsers.agentsListed(
            on: Self.dionysus, statuses: ["alpha": .running, "beta": .stopped, "restoring": .restoring], dispatches: ["d1"]
        )

        #expect(browsers.keys == Set([keys[0], keys[3], keys[4], elsewhere]))
    }

    @Test func aHostThatDoesNotListDispatchesKeepsTheirBrowsers() {
        let made = Made()
        let browsers = registry(made)
        let dispatch = LeoAgentBrowserKey.dispatch(host: Self.dionysus, id: "d1")
        _ = browsers.openBrowser(for: dispatch)

        browsers.agentsListed(on: Self.dionysus, statuses: [:], dispatches: nil)

        #expect(browsers.keys == [dispatch])
    }
}
