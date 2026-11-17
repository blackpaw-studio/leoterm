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
/// Console messages are capped in number and size: the page can post to
/// the handler directly.
@available(macOS 14, *)
@MainActor final class LeoWKBrowserPage: NSObject {
    struct Location: Equatable {
        let url: URL?
        let title: String
    }

    struct ConsoleEntry: Equatable {
        /// Grows by one per message, for `console(since:)`.
        let seq: Int
        let level: String
        let text: String

        fileprivate var bytes: Int { level.utf8.count + text.utf8.count }
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
    /// What every allowed navigation gets. Plain `.allow` first offers the
    /// URL to any app that claims it as a universal link, which would open
    /// that app. This is WebKit's
    /// `_WKNavigationActionPolicyAllowWithoutTryingAppLink` (allow + 2,
    /// `WKNavigationDelegatePrivate.h`), there since macOS 10.11, so every
    /// OS this runs on has it and there is nothing to detect at run time.
    static let allowWithoutAppLinks = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .cancel

    let webView: LeoAgentWebView

    private let input: LeoSyntheticInput
    private let allowsURL: (URL) -> Bool
    private let clock: any Clock<Duration>
    /// Bumped by every snapshot and committed navigation; a ref names the
    /// one it was made under.
    private var generation = 0
    private var consoleLog: [ConsoleEntry] = []
    /// UTF-8 bytes of the levels and texts in `consoleLog`.
    private var consoleBytes = 0
    private var consoleSeq = 0
    private var consoleCursor = 0
    private var navigations: [ObjectIdentifier: CheckedContinuation<Void, any Error>] = [:]
    /// Input operations under way; they can overlap.
    private var inputsUnderWay = 0
    /// Where the last navigation the page waited for ended, until the web
    /// view's own title catches up.
    private var lastLocation: Location?
    private var titleObservation: NSKeyValueObservation?
    /// A main-frame response was turned into a download: the navigation
    /// it ends with WebKit's "frame load interrupted" succeeded.
    private var mainFrameBecameDownload = false

    /// Each navigation or response this page turns into a download (B-404).
    var onDownload: (@MainActor (WKDownload) -> Void)?
    /// After the main frame commits a new document (B-410).
    var onCommit: (@MainActor () -> Void)?
    /// After the page's web content process stopped (B-410).
    var onContentProcessTerminate: (@MainActor () -> Void)?

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
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lastLocation = nil }
        }
    }

    /// The page's URL and title. The title comes from the document:
    /// `webView.title` can lag behind `didFinish`.
    func location() async -> Location {
        let title = try? await run("return document.title", [:], in: Self.agentWorld) as? String
        return .init(url: webView.url, title: title ?? webView.title ?? "")
    }

    // MARK: Navigation

    func navigate(to url: URL) async throws -> Location {
        guard allowsURL(url) else { throw LeoBrowserError.schemeNotAllowed(url) }
        return try await settled(webView.load(URLRequest(url: url)))
    }

    func back() async throws -> Location {
        guard webView.canGoBack else { throw LeoBrowserError.navigationFailed("There is no previous page.") }
        return try await settled(webView.goBack())
    }

    func forward() async throws -> Location {
        guard webView.canGoForward else { throw LeoBrowserError.navigationFailed("There is no next page.") }
        return try await settled(webView.goForward())
    }

    func reloadPage() async throws -> Location {
        try await settled(webView.reload())
    }

    /// Waits for `navigation`, then keeps the document's title for `title`.
    private func settled(_ navigation: WKNavigation?) async throws -> Location {
        try await settle(navigation)
        let location = await location()
        lastLocation = location
        return location
    }

    /// Waits for `navigation` to finish, fail, time out or be cancelled.
    private func settle(_ navigation: WKNavigation?) async throws {
        guard let navigation else { return }
        let key = ObjectIdentifier(navigation)
        let timer = Task { [clock] in
            try await clock.sleep(for: Self.navigationDeadline)
            self.finish(key, .failure(LeoBrowserError.timeout("The page did not finish loading in time.")))
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
        else { throw LeoBrowserError.javaScript("The snapshot script returned nothing.") }
        return LeoBrowserScripts.snapshotText(text, truncated: result["truncated"] as? Bool ?? false)
    }

    /// Scrolls `ref`'s element into view and returns its centre in the web
    /// view's coordinates.
    func locate(ref: String) async throws -> CGPoint {
        guard Self.generation(of: ref) == generation else { throw LeoBrowserError.staleRef(ref) }
        guard
            let box = try await run(LeoBrowserScripts.locateRef, ["ref": ref], in: Self.agentWorld) as? [String: Any],
            let x = box["x"] as? Double, let y = box["y"] as? Double,
            let width = box["width"] as? Double, let height = box["height"] as? Double
        else { throw LeoBrowserError.staleRef(ref) }
        return viewPoint(x: x + width / 2, y: y + height / 2)
    }

    /// A point in viewport (CSS) pixels as the web view's coordinates.
    private func viewPoint(x: Double, y: Double) -> CGPoint {
        let zoom = webView.pageZoom
        let point = CGPoint(x: x * zoom, y: y * zoom)
        return webView.isFlipped ? point : CGPoint(x: point.x, y: webView.bounds.height - point.y)
    }

    /// Evaluates `js` in the page's own world and returns the result as JSON
    /// (`null` for undefined). `js` is first tried as a single expression
    /// (awaited, so `1+1` and `fetch(u).then(r => r.json())` just work); if it
    /// doesn't parse as one, it runs as the body of an async function and
    /// needs an explicit `return`.
    func eval(_ js: String) async throws -> String {
        var result = try await run(LeoBrowserScripts.evalExpression, ["js": js], in: .page)
        if (result as? [String: Any])?["csp"] != nil {
            // No string-eval on this page: let WebKit compile the expression
            // instead. A parse failure throws and means it is statements.
            result = try? await run(LeoBrowserScripts.evalExpressionDirect(js), [:], in: .page)
        }
        if let thrown = (result as? [String: Any])?["thrown"] as? String { throw LeoBrowserError.javaScript(thrown) }
        if let json = result as? String { return json }
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
        if fullPage { return try await fullPageScreenshot() }
        let configuration = WKSnapshotConfiguration()
        let scale = webView.window?.backingScaleFactor ?? 2
        configuration.snapshotWidth = NSNumber(value: min(webView.bounds.width, Double(Self.maxScreenshotWidth) / scale))
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: LeoBrowserError.javaScript(error?.localizedDescription ?? "The screenshot failed."))
                }
            }
        }
        return try Self.png(image, maxWidth: Self.maxScreenshotWidth)
    }

    /// `takeSnapshot` paints only what is on screen: a rect taller than the
    /// viewport came back blank below it. So the whole page comes from its
    /// PDF, which WebKit renders in full, drawn at the screen's scale: at most
    /// `maxScreenshotWidth` pixels wide, and the top `maxFullPageHeight`
    /// points of a taller page.
    private func fullPageScreenshot() async throws -> Data {
        let data = try await screenshotPDF()
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw LeoBrowserError.javaScript("Could not render the page.")
        }
        // WebKit splits a PDF taller than 14,400 pt (the PDF page limit) into
        // pages; they are stacked back into one image.
        let pages = (0..<document.numberOfPages).compactMap { document.page(at: $0 + 1) }
        let boxes = pages.map { $0.getBoxRect(.mediaBox) }
        let width = boxes.map(\.width).max() ?? 0
        let height = min(boxes.reduce(0) { $0 + $1.height }, Self.maxFullPageHeight)
        guard width > 0, height > 0 else { throw LeoBrowserError.javaScript("The page is empty.") }
        let scale = min(webView.window?.backingScaleFactor ?? 2, Double(Self.maxScreenshotWidth) / width)
        guard
            let context = CGContext(
                data: nil, width: max(1, Int((width * scale).rounded(.down))), height: max(1, Int((height * scale).rounded())),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LeoBrowserError.javaScript("Could not render the page.") }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        // PDF space runs bottom-up: each page's top sits where the last one ended.
        var top = height
        for (page, box) in zip(pages, boxes) where top > 0 {
            context.saveGState()
            context.translateBy(x: -box.minX, y: top - box.maxY)
            context.drawPDFPage(page)
            context.restoreGState()
            top -= box.height
        }
        guard let image = context.makeImage() else { throw LeoBrowserError.javaScript("Could not render the page.") }
        return try Self.png(image, maxWidth: Self.maxScreenshotWidth)
    }

    /// The whole document as one continuous PDF page, as Safari's Export
    /// as PDF makes it: not the viewport, and not paginated for printing.
    func pdf() async throws -> Data {
        try await pdf(WKPDFConfiguration())
    }

    /// The PDF a full-page screenshot is drawn from: only the region the
    /// screenshot keeps (the viewport's width, the top `maxFullPageHeight`
    /// points of the document), so a very long page is never rendered whole.
    /// The rect is in document coordinates, whatever the scroll position.
    func screenshotPDF() async throws -> Data {
        let height = try await run("return document.documentElement.scrollHeight", [:], in: Self.agentWorld) as? Double
        guard let height else { throw LeoBrowserError.javaScript("Could not measure the page.") }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0, y: 0, width: webView.bounds.width, height: min(height, Self.maxFullPageHeight) * webView.pageZoom)
        return try await pdf(configuration)
    }

    private func pdf(_ configuration: WKPDFConfiguration) async throws -> Data {
        do {
            return try await webView.pdf(configuration: configuration)
        } catch {
            throw LeoBrowserError.javaScript("The PDF couldn’t be made: \(error.localizedDescription)")
        }
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
            guard waited < limit else { throw LeoBrowserError.timeout("\"\(text)\" did not appear on the page.") }
            try await clock.sleep(for: Self.waitPollInterval)
            waited += Self.waitPollInterval
        }
    }

    // MARK: File inputs

    /// The file input `ref` resolves to.
    func fileInput(ref: String) async throws -> LeoBrowserFileInput {
        let result = try await runOnRef(LeoBrowserScripts.fileInput, ref: ref, [:])
        return LeoBrowserFileInput(allowsMultiple: result["multiple"] as? Bool ?? false)
    }

    /// Replaces the files of the input `ref` resolves to, from Leo's world;
    /// the bytes travel as base64.
    func setFiles(ref: String, files: [LeoBrowserUploadFile]) async throws {
        let payload = files.map { ["name": $0.name, "type": $0.mimeType, "data": $0.data.base64EncodedString()] }
        _ = try await runOnRef(LeoBrowserScripts.setFiles, ref: ref, ["files": payload])
    }

    private func runOnRef(_ script: String, ref: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard Self.generation(of: ref) == generation else { throw LeoBrowserError.staleRef(ref) }
        let result = try await run(script, arguments.merging(["ref": ref]) { $1 }, in: Self.agentWorld) as? [String: Any]
        guard let result, result["stale"] == nil else { throw LeoBrowserError.staleRef(ref) }
        if let message = result["error"] as? String { throw LeoBrowserError.invalidArgs(message) }
        return result
    }

    // MARK: Drag

    /// How many moves a pointer drag takes from the start to the end.
    static let dragSteps = 8

    /// Drags `startRef`'s element onto `endRef`'s. An HTML5-draggable source
    /// gets script drag events: a native drag would start a drag session
    /// that follows the user's cursor. Anything else gets a real press,
    /// moves with the button down and a release; the button is released
    /// even if the call is cancelled or fails part-way.
    func drag(startRef: String, endRef: String) async throws {
        try await driving {
            try requireWindow()
            let refs = ["startRef": startRef, "endRef": endRef]
            for ref in [startRef, endRef] where Self.generation(of: ref) != generation { throw LeoBrowserError.staleRef(ref) }
            let source = try await runOnDragRefs(LeoBrowserScripts.dragSource, refs)
            guard
                let x = source["x"] as? Double, let y = source["y"] as? Double, let isHTML5 = source["html5"] as? Bool
            else { throw LeoBrowserError.staleRef(startRef) }
            guard startRef != endRef else { return }
            if isHTML5 {
                _ = try await runOnDragRefs(LeoBrowserScripts.html5Drag, refs)
            } else {
                try await pointerDrag(from: viewPoint(x: x, y: y), endRef: endRef)
            }
        }
    }

    private func runOnDragRefs(_ script: String, _ refs: [String: String]) async throws -> [String: Any] {
        let result = try await run(script, refs, in: Self.agentWorld) as? [String: Any]
        guard let result else { throw LeoBrowserError.javaScript("The drag script returned nothing.") }
        if let ref = result["stale"] as? String { throw LeoBrowserError.staleRef(ref) }
        if let message = result["error"] as? String { throw LeoBrowserError.invalidArgs(message) }
        return result
    }

    private func pointerDrag(from start: CGPoint, endRef: String) async throws {
        var last = start
        do {
            try await deliver(input.mouseDown(at: start, in: webView))
            // The end can need scrolling, so it is located once the button is down.
            let end = try await locate(ref: endRef)
            try await deliver(input.dragMoves(from: start, to: end, steps: Self.dragSteps, in: webView))
            last = end
            try await deliver(input.mouseUp(at: end, in: webView))
        } catch {
            input.deliverImmediately(input.mouseUp(at: last, in: webView), to: webView)
            throw error
        }
    }

    // MARK: Select options

    /// Selects the options `values` name in the `<select>` `ref` resolves
    /// to, from Leo's world, and reports the ones it ends with.
    func selectOption(ref: String, values: [String]) async throws -> [LeoBrowserSelectedOption] {
        let result = try await runOnRef(LeoBrowserScripts.selectOption, ref: ref, ["values": values])
        let selected = result["selected"] as? [[String: Any]] ?? []
        return selected.compactMap { entry in
            guard let value = entry["value"] as? String, let label = entry["label"] as? String else { return nil }
            return LeoBrowserSelectedOption(value: value, label: label)
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

    /// Moves the pointer onto the centre of `ref`'s element with a real
    /// mouse-move event and leaves it there.
    func hover(ref: String) async throws {
        try await driving {
            try requireWindow()
            let point = try await locate(ref: ref)
            try await deliver(input.hover(at: point, in: webView))
        }
    }

    /// Focuses `ref`'s element and types `text` over its contents with real
    /// key events; `submit` then presses Enter.
    func type(ref: String, text: String, submit: Bool) async throws {
        try await driving {
            try requireWindow()
            _ = try await locate(ref: ref)
            let focus = try await run(LeoBrowserScripts.focusRef, ["ref": ref], in: Self.agentWorld) as? [String: Any]
            guard let focus, focus["stale"] == nil else { throw LeoBrowserError.staleRef(ref) }
            try await deliver(input.type(text, in: webView))
            if submit { try await press(LeoSyntheticKey(key: "Enter")) }
        }
    }

    /// Presses `key` in whatever has focus.
    func press(_ key: LeoSyntheticKey) async throws {
        try await driving {
            try requireWindow()
            guard let events = input.press(key, in: webView) else {
                throw LeoBrowserError.invalidArgs("There is no key called \"\(key.key)\".")
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
        throw LeoBrowserError(.noSuchTab, "The tab is not open in a window.")
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

    /// Runs `body` as an async function in `world`. WebKit never answers a
    /// call whose page navigates away mid-script, or one made while the page
    /// is navigating, so cancelling (the daemon's tool timeout) ends the call
    /// at once and WebKit's late answer, if any, is dropped.
    private func run(_ body: String, _ arguments: [String: Any], in world: WKContentWorld) async throws -> Any? {
        try Task.checkCancellation()
        let answer = LeoOnce<Any?>()
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
            answer.resume(with: result.map { $0 as Any? }.mapError(Self.scriptFailure))
        }
        return try await withTaskCancellationHandler {
            try await answer.value()
        } onCancel: {
            Task { @MainActor in answer.resume(with: .failure(CancellationError())) }
        }
    }

    private nonisolated static func scriptFailure(_ error: any Error) -> any Error {
        let error = error as NSError
        let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        return LeoBrowserError.javaScript(message)
    }

    /// PNG of `image`, scaled down to at most `maxWidth` pixels wide.
    static func png(_ image: NSImage, maxWidth: Int) throws -> Data {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LeoBrowserError.javaScript("The screenshot had no bitmap.")
        }
        return try png(source, maxWidth: maxWidth)
    }

    static func png(_ source: CGImage, maxWidth: Int) throws -> Data {
        let scale = min(1, Double(maxWidth) / Double(source.width))
        let width = Int((Double(source.width) * scale).rounded(.down))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LeoBrowserError.javaScript("Could not scale the screenshot.") }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard
            let scaled = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw LeoBrowserError.javaScript("Could not encode the screenshot.") }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw LeoBrowserError.javaScript("Could not encode the screenshot.") }
        return data as Data
    }
}

// MARK: - LeoBrowserPage

/// What the executor drives. Failures are already `LeoBrowserError`s, so
/// the agent sees the page's own codes.
@available(macOS 14, *)
extension LeoWKBrowserPage: LeoBrowserPage {
    var url: URL? { webView.url }

    /// The document's title from the last navigation waited for, until the
    /// web view's own title changes.
    var title: String {
        if let lastLocation, lastLocation.url == webView.url { return lastLocation.title }
        return webView.title ?? ""
    }

    func load(_ url: URL) async throws { _ = try await navigate(to: url) }
    func goBack() async throws { _ = try await back() }
    func goForward() async throws { _ = try await forward() }
    func reload() async throws { _ = try await reloadPage() }
    func press(_ combo: LeoBrowserKeyCombo) async throws { try await press(LeoSyntheticKey(combo)) }

    func waitForText(_ text: String, timeoutMilliseconds: Int) async throws {
        try await wait(for: text, ms: timeoutMilliseconds)
    }

    func evaluate(_ js: String) async throws -> String { try await eval(js) }

    /// `WKWebView.customUserAgent` replaces the whole user agent, both in the
    /// request header and in `navigator.userAgent`; nil restores the default
    /// (the configuration's Safari-versioned one).
    func setUserAgent(_ userAgent: String?) { webView.customUserAgent = userAgent }

    func consoleMessages(since: Int?) -> LeoBrowserConsoleBatch {
        let entries = console(since: since)
        return LeoBrowserConsoleBatch(entries: entries.map { LeoBrowserConsoleEntry(level: $0.level, text: $0.text) }, cursor: consoleSeq)
    }
}

extension LeoBrowserError {
    fileprivate static func javaScript(_ message: String) -> Self { Self(.jsError, message) }
    fileprivate static func navigationFailed(_ message: String) -> Self { Self(.navigationFailed, message) }
    fileprivate static func timeout(_ message: String) -> Self { Self(.timeout, message) }

    fileprivate static func schemeNotAllowed(_ url: URL) -> Self {
        Self(.schemeNotAllowed, "Only http, https and about:blank pages can be opened, not \(url.scheme ?? "this URL").")
    }
}

// MARK: - WKNavigationDelegate

@available(macOS 14, *)
extension LeoWKBrowserPage: WKNavigationDelegate {
    /// WebKit's `WebKitErrorFrameLoadInterruptedByPolicyChange` (legacy
    /// `WebKitErrorDomain`, not `WKErrorDomain`): what a navigation that
    /// became a download ends with.
    static let frameLoadInterruptedDomain = "WebKitErrorDomain"
    static let frameLoadInterruptedCode = 102

    /// An `<a download>` link downloads (never a local file); everything
    /// else follows `navigationPolicy`.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload {
            guard let url = navigationAction.request.url, !url.isFileURL else { return .cancel }
            return .download
        }
        return navigationPolicy(for: navigationAction.request.url, isSubframe: navigationAction.targetFrame?.isMainFrame == false)
    }

    /// An attachment, or anything the browser can't show, downloads -- in a
    /// subframe too, which is how many sites start a download.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard Self.isDownload(navigationResponse.response, canShowMIMEType: navigationResponse.canShowMIMEType) else { return .allow }
        if navigationResponse.isForMainFrame { mainFrameBecameDownload = true }
        return .download
    }

    static func isDownload(_ response: URLResponse, canShowMIMEType: Bool) -> Bool {
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let type = disposition.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        return type == "attachment" || !canShowMIMEType
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        onDownload?(download)
    }

    /// What a navigation to `url` gets in a subframe, or else in the main
    /// frame or a new window. The scheme rule is about where the agent
    /// goes: a subframe may hold any web content, but never a local file.
    func navigationPolicy(for url: URL?, isSubframe: Bool) -> WKNavigationActionPolicy {
        guard let url else { return .cancel }
        let isAllowed = isSubframe ? !url.isFileURL : allowsURL(url)
        return isAllowed ? Self.allowWithoutAppLinks : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        generation += 1
        mainFrameBecameDownload = false
        onCommit?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        mainFrameBecameDownload = false
        finish(ObjectIdentifier(navigation), .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(ObjectIdentifier(navigation), outcome(of: error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(ObjectIdentifier(navigation), outcome(of: error))
    }

    /// A load the page itself turned into a download succeeded (the page
    /// stays where it was); any other failure, a real 102 included, fails.
    private func outcome(of error: any Error) -> Result<Void, any Error> {
        let error = error as NSError
        if mainFrameBecameDownload, error.domain == Self.frameLoadInterruptedDomain, error.code == Self.frameLoadInterruptedCode {
            mainFrameBecameDownload = false
            return .success(())
        }
        return .failure(LeoBrowserError.navigationFailed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        for key in navigations.keys {
            finish(key, .failure(LeoBrowserError.navigationFailed("The page's web content process stopped.")))
        }
        onContentProcessTerminate?()
    }
}

// MARK: - Console

@available(macOS 14, *)
extension LeoWKBrowserPage: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
        let level = (body["level"] as? String).flatMap { LeoBrowserScripts.consoleLevels.contains($0) ? $0 : nil } ?? "log"
        noteConsole(level: level, text: text)
    }

    /// Adds an entry to the page's console as if the page had logged it:
    /// the browser reports what it refused to do for the page (a new window
    /// past the tab cap) where the agent reads the page's own messages.
    func noteConsole(level: String, text: String) {
        consoleSeq += 1
        let entry = ConsoleEntry(seq: consoleSeq, level: level, text: LeoBrowserScripts.consoleText(text))
        consoleLog.append(entry)
        consoleBytes += entry.bytes
        while consoleLog.count > LeoBrowserScripts.consoleCapacity || consoleBytes > LeoBrowserScripts.consoleBufferLimit {
            consoleBytes -= consoleLog.removeFirst().bytes
        }
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
