import AVFoundation
import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-410 on real WebKit: a page's location and microphone requests reach
/// the browser's UI delegate, and a deny reaches the page. Deny only: these
/// tests never grant, so no system permission prompt ever appears. Pages
/// come from a loopback HTTP server, a secure context for these APIs.
@MainActor
@Suite(.serialized)
struct LeoWKBrowserPermissionTests {
    private static let page = "<title>Permissions</title><p>Ready</p>"

    /// A capture device is required: WebKit fails `getUserMedia` before it
    /// asks the delegate on a Mac with no microphone. Microphone access must
    /// also be decided already: while it is undetermined, macOS may show its
    /// own prompt, which nobody answers on a fresh CI VM, so the test hangs.
    private nonisolated static var hasMicrophone: Bool {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices.isEmpty == false
            && AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
    }

    /// No pane shows this browser, so every request is denied at once.
    @available(macOS 14, *)
    private func browser() -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return LeoAgentBrowser(
            key: LeoAgentBrowserKey(host: .local, agent: "alfred"), configuration: configuration, urlMapping: LeoIdentityURLMapping(),
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600)))
        )
    }

    @available(macOS 14, *)
    private func deniedLines(_ browser: LeoAgentBrowser) throws -> [String] {
        try #require(browser.tabs.page(forTab: nil)).consoleMessages(since: 0).entries.map(\.text)
            .filter { $0.hasPrefix(LeoBrowserPermissionText.deniedCode) }
    }

    @available(macOS 14, *)
    @Test func geolocationReachesTheDelegateAndPageSeesDenied() async throws {
        let server = try LeoHTTPFixtureServer(pages: ["geo": Self.page])
        defer { server.stop() }
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: server.url("geo"))
        let page = try #require(browser.tabs.page(forTab: nil))

        let result = try await page.evaluate("""
        return await new Promise(resolve => navigator.geolocation.getCurrentPosition(
            () => resolve('granted'), error => resolve('error ' + error.code)))
        """)

        #expect(result == #""error 1""#, "PERMISSION_DENIED")
        #expect(try deniedLines(browser) == [
            LeoBrowserPermissionText.deniedLine(kind: .location, origin: "http://127.0.0.1:\(server.port)", because: .notShown),
        ])
    }

    @available(macOS 14, *)
    @Test(.enabled(if: hasMicrophone, "needs a microphone"))
    func microphoneReachesTheDelegate() async throws {
        let server = try LeoHTTPFixtureServer(pages: ["mic": Self.page])
        defer { server.stop() }
        let browser = browser()
        defer { browser.close() }
        _ = try await browser.tabs.openTab(url: server.url("mic"))
        let page = try #require(browser.tabs.page(forTab: nil))

        let result = try await page.evaluate("""
        return await navigator.mediaDevices.getUserMedia({ audio: true }).then(() => 'granted', error => error.name)
        """)

        #expect(result == #""NotAllowedError""#)
        #expect(try deniedLines(browser) == [
            LeoBrowserPermissionText.deniedLine(kind: .microphone, origin: "http://127.0.0.1:\(server.port)", because: .notShown),
        ])
    }
}
