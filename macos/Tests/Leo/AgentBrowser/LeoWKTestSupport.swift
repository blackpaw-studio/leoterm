import AppKit
import LeoKit
import WebKit

@testable import Ghostty

/// Agent-browser WebKit tests need a window-server session: web views
/// render and take input only inside real windows.
enum LeoWKTestHost {
    static var hasWindowServer: Bool { !NSScreen.screens.isEmpty }

    /// A frame for a window that no screen shows.
    static func offscreenFrame(size: CGSize) -> NSRect {
        let screens = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
        return NSRect(origin: CGPoint(x: screens.maxX + 2_000, y: screens.maxY + 2_000), size: size)
    }

    /// A plain borderless window off every screen, for tests that only
    /// need the web view to sit in a window.
    /// The test host is the app, so its `NSApp` is Leo's.
    @MainActor static var application: LeoApplication {
        guard let application = NSApp as? LeoApplication else {
            fatalError("The test host's NSApp is a \(type(of: NSApp)), not a LeoApplication")
        }
        return application
    }

    @MainActor static func offscreenWindow(size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: offscreenFrame(size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }
}

/// Serves in-memory pages at `leotest://fixture/<name>`.
@MainActor final class LeoWKFixtureServer: NSObject, WKURLSchemeHandler {
    static let scheme = "leotest"

    private let pages: [String: String]

    init(_ pages: [String: String]) {
        self.pages = pages
    }

    static func url(_ name: String) -> URL {
        URL(string: "\(scheme)://fixture/\(name)")!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let html = pages[url.lastPathComponent] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@available(macOS 14, *)
extension LeoWKBrowserPage {
    /// A page over `pages` with a fresh non-persistent store. Fixture,
    /// http(s) and about: URLs are allowed.
    static func fixture(_ pages: [String: String]) -> LeoWKBrowserPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LeoWKFixtureServer(pages), forURLScheme: LeoWKFixtureServer.scheme)
        return LeoWKBrowserPage(
            configuration: configuration,
            allowsURL: { url in [LeoWKFixtureServer.scheme, "http", "https", "about"].contains(url.scheme ?? "") },
            input: LeoSyntheticInput(application: LeoWKTestHost.application))
    }

    /// The error code `body` failed with, or nil when it succeeded.
    func failureCode<T>(_ body: (LeoWKBrowserPage) async throws -> T) async -> String? {
        do {
            _ = try await body(self)
            return nil
        } catch let failure as LeoBrowserError {
            return failure.code.rawValue
        } catch {
            return "unexpected: \(error)"
        }
    }
}

/// A fixture page in its own off-screen window, as a parked tab sits.
@available(macOS 14, *)
@MainActor final class LeoWKPageFixture {
    let window = LeoWKTestHost.offscreenWindow(size: CGSize(width: 800, height: 600))
    let page: LeoWKBrowserPage

    init(_ pages: [String: String]) {
        page = .fixture(pages)
        page.webView.frame = window.contentView!.bounds
        page.webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(page.webView)
    }

    func close() {
        page.webView.removeFromSuperview()
        window.close()
    }
}

/// The first ref on the snapshot line for `prefix` (e.g. `button "Go"`).
func leoSnapshotRef(_ snapshot: String, _ prefix: String) -> String? {
    let line = snapshot.split(separator: "\n").first { $0.contains("- \(prefix) [ref=") }
    guard let line, let range = line.range(of: #"\[ref=(s\d+e\d+)\]"#, options: .regularExpression) else { return nil }
    return String(line[range].dropFirst("[ref=".count).dropLast())
}
