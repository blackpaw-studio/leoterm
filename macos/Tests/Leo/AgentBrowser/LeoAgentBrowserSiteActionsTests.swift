import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-409: what the browser hands Open in Default Browser (the address Leo
/// itself loads, through the machine's forward for a remote loopback page),
/// and Clear Site Data emptying one agent's store and no other.
@MainActor
@Suite(.serialized)
struct LeoAgentBrowserSiteActionsTests {
    private nonisolated static let key = LeoAgentBrowserKey(host: .remote("dionysus"), agent: "alpha")

    /// Stands in for a machine's forward: the remote `localhost:<remotePort>`
    /// is `127.0.0.1:<localPort>` on this Mac.
    @MainActor private final class FakeForward: LeoBrowserURLMapping {
        let remotePort: Int
        let localPort: Int

        init(remotePort: Int, localPort: Int) {
            self.remotePort = remotePort
            self.localPort = localPort
        }

        func toLocal(_ url: URL) async throws -> URL {
            Self.replace(url, host: "localhost", port: remotePort, with: "127.0.0.1", localPort)
        }

        func toRemote(_ url: URL) -> URL {
            Self.replace(url, host: "127.0.0.1", port: localPort, with: "localhost", remotePort)
        }

        private static func replace(_ url: URL, host: String, port: Int, with newHost: String, _ newPort: Int) -> URL {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host == host, parts.port == port else { return url }
            parts.host = newHost
            parts.port = newPort
            return parts.url ?? url
        }
    }

    @available(macOS 14, *)
    private func browser(key: LeoAgentBrowserKey = Self.key, mapping: any LeoBrowserURLMapping) -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return LeoAgentBrowser(
            key: key, configuration: configuration, urlMapping: mapping,
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)))
        )
    }

    // MARK: - Open in Default Browser

    @available(macOS 14, *)
    @Test func externalURLUsesTheForwardedPortForRemoteLoopback() async throws {
        let server = try LeoHTTPFixtureServer(pages: ["x": "<title>X</title>"])
        defer { server.stop() }
        let browser = browser(mapping: FakeForward(remotePort: 5173, localPort: Int(server.port)))
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: try #require(URL(string: "http://127.0.0.1:\(server.port)/x?q=1#f")))
        #expect(browser.activeRemoteURL?.absoluteString == "http://localhost:5173/x?q=1#f")

        let url = try await browser.externalURL()

        #expect(url?.absoluteString == "http://127.0.0.1:\(server.port)/x?q=1#f")
    }

    @available(macOS 14, *)
    @Test func externalURLOfALocalAgentsPageIsItsOwnURL() async throws {
        let server = try LeoHTTPFixtureServer(pages: ["x": "<title>X</title>"])
        defer { server.stop() }
        let browser = browser(key: LeoAgentBrowserKey(host: .local, agent: "alpha"), mapping: LeoIdentityURLMapping())
        defer { browser.close() }
        let page = server.url("x")
        _ = try await browser.tabs.openTab(url: page)

        #expect(try await browser.externalURL() == page)
    }

    /// The real mapping of a machine that isn't connected: nothing to open,
    /// and the reason names the machine and the port.
    @available(macOS 14, *)
    @Test func externalURLExplainsWhenTheMachineIsNotConnected() async throws {
        let server = try LeoHTTPFixtureServer(pages: ["x": "<title>X</title>"])
        defer { server.stop() }
        let forwards = LeoMachinePortForwards(makeForwards: { _ in nil })
        let browser = browser(mapping: forwards.mapping(for: Self.key))
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: server.url("x"))

        do {
            let url = try await browser.externalURL()
            Issue.record("expected a reason, got \(String(describing: url))")
        } catch let error as LeoBrowserError {
            #expect(error.message.contains("dionysus"))
            #expect(error.message.contains("\(server.port)"))
        }
        withExtendedLifetime(forwards) {}
    }

    @available(macOS 14, *)
    @Test func externalURLIsNilForABlankTabOrNoTab() async throws {
        let browser = browser(mapping: LeoIdentityURLMapping())
        defer { browser.close() }
        #expect(try await browser.externalURL() == nil)

        _ = try await browser.tabs.openTab(url: try #require(URL(string: "about:blank")))

        #expect(try await browser.externalURL() == nil)
    }

    // MARK: - Clear Site Data

    private static func cookie(_ name: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [.name: name, .value: "1", .domain: "example.com", .path: "/", .expires: Date.distantFuture]))
    }

    /// Real stores on random machine ids. The same agent name on another
    /// machine and another agent on the same machine keep their data.
    @available(macOS 14, *)
    @Test func clearSiteDataEmptiesOnlyThatAgentsStore() async throws {
        let machines: [LeoHostID: String] = [.remote("one"): "test-\(UUID().uuidString)", .remote("two"): "test-\(UUID().uuidString)"]
        let factory = LeoAgentBrowserFactory(
            machineID: { machines[$0] ?? "test-unknown" }, urlMapping: { _ in LeoIdentityURLMapping() },
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)))
        )
        let cleared = factory.make(LeoAgentBrowserKey(host: .remote("one"), agent: "alpha"))
        let sibling = factory.make(LeoAgentBrowserKey(host: .remote("one"), agent: "beta"))
        let namesake = factory.make(LeoAgentBrowserKey(host: .remote("two"), agent: "alpha"))
        let browsers = [cleared, sibling, namesake]
        let stores = Set(browsers.compactMap(\.dataStore.identifier))
        #expect(stores.count == 3)
        for (index, browser) in browsers.enumerated() {
            await browser.dataStore.httpCookieStore.setCookie(try Self.cookie("c\(index)"))
        }

        #expect(!cleared.isClearingSiteData)
        await cleared.clearSiteData()

        #expect(!cleared.isClearingSiteData)
        #expect(await cleared.dataStore.httpCookieStore.allCookies().isEmpty)
        #expect(await cleared.dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).isEmpty)
        #expect(await sibling.dataStore.httpCookieStore.allCookies().map(\.name) == ["c1"])
        #expect(await namesake.dataStore.httpCookieStore.allCookies().map(\.name) == ["c2"])
        browsers.forEach { $0.close() }
        for store in stores { try? await WKWebsiteDataStore.remove(forIdentifier: store) }
    }
}
