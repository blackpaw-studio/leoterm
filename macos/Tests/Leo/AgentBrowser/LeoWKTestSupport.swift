import AppKit
import LeoKit
import WebKit

@testable import Ghostty

/// Agent-browser WebKit tests need a window-server session: web views
/// render and take input only inside real windows.
enum LeoWKTestHost {
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

/// Deterministic end of life for a fixture window that holds views.
enum LeoFixtureWindow {
    /// Takes the content out of the window while it is still alive. A window
    /// that deallocates with a web view inside tears the view tree down
    /// mid-dealloc, and WebKit/AppKit then form weak references to the dying
    /// window (the "Cannot form weak reference ... NSKVONotifying_" trap).
    /// Not `close()`: the fixtures' key-window stand-ins report `isKeyWindow`
    /// without being key, and closing one crashes the host.
    ///
    /// Callable from a suite's nonisolated `deinit`, which Swift Testing may run
    /// off the main thread: then the detach hops to the main queue, and its
    /// closure keeps the window alive until it has run.
    static func tearDown(_ window: NSWindow) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { window.contentView = nil }
            return
        }
        MainActor.assumeIsolated { window.contentView = nil }
    }
}

/// Serves in-memory pages at `leotest://fixture/<name>`.
@MainActor final class LeoWKFixtureServer: NSObject, WKURLSchemeHandler {
    static let scheme = "leotest"

    private let pages: [String: String]
    /// The `User-Agent` header of each request served, in order (nil when absent).
    private(set) var userAgents: [String?] = []

    init(_ pages: [String: String]) {
        self.pages = pages
    }

    static func url(_ name: String) -> URL {
        URL(string: "\(scheme)://fixture/\(name)")!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        userAgents.append(urlSchemeTask.request.value(forHTTPHeaderField: "User-Agent"))
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

/// A file the HTTP fixture server sends.
struct LeoWKFixtureFile {
    var data: Data
    var mimeType = "application/octet-stream"
    /// Sent as `Content-Disposition: attachment; filename="…"` when set.
    var attachmentName: String?
    /// Sends half the bytes, then holds the connection until
    /// `failHeldLoads()` drops it mid-body.
    var failsMidway = false
}

/// A loopback HTTP/1.0 server for tests WebKit's custom-scheme handlers
/// can't serve (downloads): `pages` as HTML, `files` with their headers, at
/// `http://127.0.0.1:<port>/<name>`. One thread per connection.
final class LeoHTTPFixtureServer: @unchecked Sendable {
    let port: UInt16
    private let pages: [String: String]
    private let files: [String: LeoWKFixtureFile]
    private let listener: Int32
    private let lock = NSLock()
    private var held: [Int32] = []

    init(pages: [String: String], files: [String: LeoWKFixtureFile] = [:]) throws {
        self.pages = pages
        self.files = files
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw URLError(.cannotConnectToHost) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && listen(descriptor, 16) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(descriptor)
            throw URLError(.cannotConnectToHost)
        }
        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in acceptLoop() }.start()
    }

    func url(_ name: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(name)")!
    }

    /// Drops every held connection mid-body.
    func failHeldLoads() {
        let connections = lock.withLock {
            defer { held = [] }
            return held
        }
        connections.forEach { Darwin.close($0) }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        failHeldLoads()
    }

    private func acceptLoop() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            _ = fcntl(connection, F_SETNOSIGPIPE, 1)
            Thread { [self] in serve(connection) }.start()
        }
    }

    private func serve(_ connection: Int32) {
        guard let name = Self.requestedName(connection) else {
            Darwin.close(connection)
            return
        }
        if let file = files[name] {
            var headers = "Content-Type: \(file.mimeType)\r\nContent-Length: \(file.data.count)\r\n"
            if let attachment = file.attachmentName { headers += "Content-Disposition: attachment; filename=\"\(attachment)\"\r\n" }
            let body = file.failsMidway ? file.data.prefix(file.data.count / 2) : file.data
            Self.write(Data("HTTP/1.0 200 OK\r\n\(headers)\r\n".utf8) + body, to: connection)
            guard file.failsMidway else {
                Darwin.close(connection)
                return
            }
            lock.withLock { held.append(connection) }
            return
        }
        guard let html = pages[name] else {
            Self.write(Data("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), to: connection)
            Darwin.close(connection)
            return
        }
        let body = Data(html.utf8)
        Self.write(Data("HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body, to: connection)
        Darwin.close(connection)
    }

    /// The last path component of the request line's target.
    private static func requestedName(_ connection: Int32) -> String? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil, request.count < 65_536 {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return nil }
            request.append(contentsOf: buffer[0..<count])
        }
        guard let line = String(data: request, encoding: .utf8)?.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1].split(separator: "?").first ?? "").split(separator: "/").last.map(String.init) ?? ""
    }

    private static func write(_ data: Data, to connection: Int32) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(connection, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
