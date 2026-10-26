import AppKit
import ImageIO
import LeoKit
import UniformTypeIdentifiers
import WebKit

/// One agent-browser tab on WebKit: the operations the executor runs
/// against a page, over a web view this object owns.
///
/// Snapshot refs live in an isolated content world, so the page's DOM and
/// scripts never see them; a ref is good until the tab's next snapshot or
/// committed navigation. Console output is hooked in the page world and
/// kept here, so it survives navigations. Each page gets its own copy of
/// the configuration with a fresh user content controller, so tabs never
/// share message handlers; a copy keeps a popup's opener relationship.
@available(macOS 14, *)
@MainActor final class LeoWKBrowserPage: NSObject {
    struct Failure: Error, Equatable {
        let code: String
        let message: String

        static func staleRef(_ ref: String) -> Self {
            .init(code: "stale_ref", message: "Ref \(ref) is not from the latest snapshot of this page; take a new snapshot.")
        }

        static func javaScript(_ message: String) -> Self { .init(code: "js_error", message: message) }
        static func navigationFailed(_ message: String) -> Self { .init(code: "navigation_failed", message: message) }
        static func timeout(_ message: String) -> Self { .init(code: "timeout", message: message) }

        static func schemeNotAllowed(_ url: URL) -> Self {
            .init(code: "scheme_not_allowed", message: "Only http, https and about:blank pages can be opened, not \(url.scheme ?? "this URL").")
        }
    }

    struct Location: Equatable {
        let url: URL?
        let title: String
    }

    struct ConsoleEntry: Equatable {
        /// Grows by one per message, for `console(since:)`.
        let seq: Int
        let level: String
        let text: String
    }

    /// Where snapshot refs live.
    static let agentWorld = WKContentWorld.world(name: "LeoAgent")
    /// Shorter than the daemon's 30 s tool timeout, so the agent gets a
    /// meaningful `timeout` first.
    static let navigationDeadline: Duration = .seconds(28)
    static let defaultWaitDeadline: Duration = .seconds(25)
    static let waitPollInterval: Duration = .milliseconds(100)
    static let maxScreenshotWidth = 1_600
    /// Full-page screenshots stop here, in CSS pixels, to bound memory.
    static let maxFullPageHeight = 16_384.0

    let webView: LeoAgentWebView

    private let input: LeoSyntheticInput
    private let allowsURL: (URL) -> Bool
    private let clock: any Clock<Duration>
    /// Bumped by every snapshot and committed navigation; a ref names the
    /// one it was made under.
    private var generation = 0
    private var consoleLog: [ConsoleEntry] = []
    private var consoleSeq = 0
    private var consoleCursor = 0
    private var navigations: [ObjectIdentifier: CheckedContinuation<Void, any Error>] = [:]
    /// Input operations under way; they can overlap.
    private var inputsUnderWay = 0

    init(
        configuration: WKWebViewConfiguration, allowsURL: @escaping (URL) -> Bool,
        input: LeoSyntheticInput, clock: any Clock<Duration> = ContinuousClock()
    ) {
        let configuration = configuration.copy() as? WKWebViewConfiguration ?? configuration
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: LeoBrowserScripts.console, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        configuration.userContentController = controller
        webView = LeoAgentWebView(frame: .zero, configuration: configuration)
        webView.isSynthetic = { [weak input] in input?.isSynthetic($0) ?? false }
        webView.keepAnimatingWhileParked()
        self.input = input
        self.allowsURL = allowsURL
        self.clock = clock
        super.init()
        controller.add(LeoWeakScriptMessageHandler(self), contentWorld: .page, name: LeoBrowserScripts.consoleHandlerName)
        webView.navigationDelegate = self
    }

    /// The page's URL and title. The title comes from the document:
    /// `webView.title` can lag behind `didFinish`.
    func location() async -> Location {
        let title = try? await run("return document.title", [:], in: Self.agentWorld) as? String
        return .init(url: webView.url, title: title ?? webView.title ?? "")
    }

    // MARK: Navigation

    func navigate(to url: URL) async throws -> Location {
        guard allowsURL(url) else { throw Failure.schemeNotAllowed(url) }
        try await settle(webView.load(URLRequest(url: url)))
        return await location()
    }

    func back() async throws -> Location {
        guard webView.canGoBack else { throw Failure.navigationFailed("There is no previous page.") }
        try await settle(webView.goBack())
        return await location()
    }

    func forward() async throws -> Location {
        guard webView.canGoForward else { throw Failure.navigationFailed("There is no next page.") }
        try await settle(webView.goForward())
        return await location()
    }

    func reload() async throws -> Location {
        try await settle(webView.reload())
        return await location()
    }

    /// Waits for `navigation` to finish, fail, time out or be cancelled.
    private func settle(_ navigation: WKNavigation?) async throws {
        guard let navigation else { return }
        let key = ObjectIdentifier(navigation)
        let timer = Task { [clock] in
            try await clock.sleep(for: Self.navigationDeadline)
            self.finish(key, .failure(Failure.timeout("The page did not finish loading in time.")))
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { navigations[key] = $0 }
        } onCancel: {
            Task { @MainActor in self.finish(key, .failure(CancellationError())) }
        }
    }

    private func finish(_ key: ObjectIdentifier, _ result: Result<Void, any Error>) {
        navigations.removeValue(forKey: key)?.resume(with: result)
    }

    // MARK: Reading the page

    func snapshot() async throws -> String {
        generation += 1
        let arguments: [String: Any] = ["gen": generation, "limit": LeoBrowserScripts.snapshotLimit]
        guard
            let result = try await run(LeoBrowserScripts.snapshot, arguments, in: Self.agentWorld) as? [String: Any],
            let text = result["text"] as? String
        else { throw Failure.javaScript("The snapshot script returned nothing.") }
        return LeoBrowserScripts.snapshotText(text, truncated: result["truncated"] as? Bool ?? false)
    }

    /// Scrolls `ref`'s element into view and returns its centre in the web
    /// view's coordinates.
    func locate(ref: String) async throws -> CGPoint {
        guard Self.generation(of: ref) == generation else { throw Failure.staleRef(ref) }
        guard
            let box = try await run(LeoBrowserScripts.locateRef, ["ref": ref], in: Self.agentWorld) as? [String: Any],
            let x = box["x"] as? Double, let y = box["y"] as? Double,
            let width = box["width"] as? Double, let height = box["height"] as? Double
        else { throw Failure.staleRef(ref) }
        let zoom = webView.pageZoom
        let center = CGPoint(x: (x + width / 2) * zoom, y: (y + height / 2) * zoom)
        return webView.isFlipped ? center : CGPoint(x: center.x, y: webView.bounds.height - center.y)
    }

    /// Runs `js` as the body of an async function in the page's own world
    /// and returns its result as JSON (`null` for undefined).
    func eval(_ js: String) async throws -> String {
        let body = "return JSON.stringify(await (async () => {\n\(js)\n})()) ?? 'null';"
        return try await run(body, [:], in: .page) as? String ?? "null"
    }

    /// Console messages after `seq`, or after the last call's when nil.
    func console(since seq: Int? = nil) -> [ConsoleEntry] {
        let entries = consoleLog.filter { $0.seq > (seq ?? consoleCursor) }
        consoleCursor = max(consoleCursor, entries.last?.seq ?? 0)
        return entries
    }

    /// The viewport, or with `fullPage` the whole document, as a PNG at
    /// most `maxScreenshotWidth` pixels wide.
    func screenshot(fullPage: Bool) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        if fullPage {
            let size = try await run("return [scrollX, scrollY, document.documentElement.scrollHeight]", [:], in: Self.agentWorld) as? [Double]
            guard let size, size.count == 3 else { throw Failure.javaScript("Could not measure the page.") }
            let zoom = webView.pageZoom
            configuration.rect = CGRect(
                x: -size[0] * zoom, y: -size[1] * zoom,
                width: webView.bounds.width, height: min(size[2], Self.maxFullPageHeight) * zoom)
        }
        let scale = webView.window?.backingScaleFactor ?? 2
        configuration.snapshotWidth = NSNumber(value: min(webView.bounds.width, Double(Self.maxScreenshotWidth) / scale))
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: Failure.javaScript(error?.localizedDescription ?? "The screenshot failed."))
                }
            }
        }
        return try Self.png(image, maxWidth: Self.maxScreenshotWidth)
    }

    /// With `text`, waits until the page's text contains it, for up to
    /// `ms` (default 25 s); without, just waits `ms`.
    func wait(for text: String?, ms: Int?) async throws {
        guard let text else {
            try await clock.sleep(for: .milliseconds(ms ?? 0))
            return
        }
        let limit = ms.map { Duration.milliseconds($0) } ?? Self.defaultWaitDeadline
        let probe = "return !!document.body && document.body.innerText.includes(text)"
        var waited = Duration.zero
        while try await run(probe, ["text": text], in: Self.agentWorld) as? Bool != true {
            guard waited < limit else { throw Failure.timeout("\"\(text)\" did not appear on the page.") }
            try await clock.sleep(for: Self.waitPollInterval)
            waited += Self.waitPollInterval
        }
    }

    // MARK: Input

    /// Clicks the centre of `ref`'s element with real mouse events.
    func click(ref: String) async throws {
        try await driving {
            try requireWindow()
            let point = try await locate(ref: ref)
            try await deliver(input.click(at: point, in: webView))
        }
    }

    /// Focuses `ref`'s element and types `text` over its contents with real
    /// key events; `submit` then presses Enter.
    func type(ref: String, text: String, submit: Bool) async throws {
        try await driving {
            try requireWindow()
            _ = try await locate(ref: ref)
            let focus = try await run(LeoBrowserScripts.focusRef, ["ref": ref], in: Self.agentWorld) as? [String: Any]
            guard let focus, focus["stale"] == nil else { throw Failure.staleRef(ref) }
            try await deliver(input.type(text, in: webView))
            if submit { try await press(LeoSyntheticKey(key: "Enter")) }
        }
    }

    /// Presses `key` in whatever has focus.
    func press(_ key: LeoSyntheticKey) async throws {
        try await driving {
            try requireWindow()
            guard let events = input.press(key, in: webView) else {
                throw Failure(code: "invalid_args", message: "There is no key called \"\(key.key)\".")
            }
            try await deliver(events)
        }
    }

    /// Runs one input operation with the web view in the agent's hands.
    private func driving(_ operation: () async throws -> Void) async throws {
        inputsUnderWay += 1
        webView.isAgentDriving = true
        defer {
            inputsUnderWay -= 1
            webView.isAgentDriving = inputsUnderWay > 0
        }
        try await operation()
    }

    /// Synthesized events carry their window's number.
    private func requireWindow() throws {
        guard webView.window == nil else { return }
        throw Failure(code: "no_such_tab", message: "The tab is not open in a window.")
    }

    /// Hands each event to the web view, then waits for a script round trip:
    /// it reaches the web content process after the input already sent, so
    /// the page has handled each event before the next one.
    private func deliver(_ events: [NSEvent]) async throws {
        try await input.deliver(events, to: webView) {
            _ = try await run("return 0", [:], in: Self.agentWorld)
        }
    }

    // MARK: Helpers

    /// `s<gen>e<n>` → gen.
    private static func generation(of ref: String) -> Int? {
        guard ref.hasPrefix("s"), let e = ref.firstIndex(of: "e") else { return nil }
        return Int(ref[ref.index(after: ref.startIndex)..<e])
    }

    private func run(_ body: String, _ arguments: [String: Any], in world: WKContentWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                continuation.resume(with: result.map { $0 as Any? }.mapError(Self.scriptFailure))
            }
        }
    }

    private nonisolated static func scriptFailure(_ error: any Error) -> any Error {
        let error = error as NSError
        let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        return Failure.javaScript(message)
    }

    /// PNG of `image`, scaled down to at most `maxWidth` pixels wide.
    static func png(_ image: NSImage, maxWidth: Int) throws -> Data {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.javaScript("The screenshot had no bitmap.")
        }
        let scale = min(1, Double(maxWidth) / Double(source.width))
        let width = Int((Double(source.width) * scale).rounded(.down))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.javaScript("Could not scale the screenshot.") }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard
            let scaled = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.javaScript("Could not encode the screenshot.") }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.javaScript("Could not encode the screenshot.") }
        return data as Data
    }
}

// MARK: - WKNavigationDelegate

@available(macOS 14, *)
extension LeoWKBrowserPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url else { return .allow }
        return allowsURL(url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        generation += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(ObjectIdentifier(navigation), .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(ObjectIdentifier(navigation), .failure(Failure.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(ObjectIdentifier(navigation), .failure(Failure.navigationFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        for key in navigations.keys {
            finish(key, .failure(Failure.navigationFailed("The page's web content process stopped.")))
        }
    }
}

// MARK: - Console

@available(macOS 14, *)
extension LeoWKBrowserPage: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            let body = message.body as? [String: Any],
            let level = body["level"] as? String,
            let text = body["text"] as? String
        else { return }
        consoleSeq += 1
        consoleLog.append(ConsoleEntry(seq: consoleSeq, level: level, text: text))
        consoleLog.removeFirst(max(0, consoleLog.count - LeoBrowserScripts.consoleCapacity))
    }
}

/// Holds its target weakly: a user content controller keeps its handlers
/// alive, and the page owns the controller.
@MainActor private final class LeoWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
