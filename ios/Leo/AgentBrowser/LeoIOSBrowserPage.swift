import ImageIO
import LeoKit
import UIKit
import UniformTypeIdentifiers
import WebKit

/// One agent-browser tab on iPhone (B-305): the operations the executor
/// runs against a page, over a web view this object owns. The Mac's
/// `LeoWKBrowserPage` is the model; what differs is input. UIKit can't post
/// touches or keys into a web view, so the agent's clicks, typing and keys
/// are DOM events from `LeoBrowserScripts`' input scripts, and the user's
/// own input is told apart because only it is real: a tap the web view's
/// recognizer sees, or a trusted keydown. Scrolling, zooming and Find send
/// neither, so they never take control.
///
/// Snapshot refs live in Leo's own content world, so the page never sees
/// them; a ref is good until the tab's next snapshot or committed navigation.
@MainActor final class LeoIOSBrowserPage: NSObject {
    static let agentWorld = WKContentWorld.world(name: "LeoAgent")
    /// Shorter than the daemon's 30 s tool timeout, so the agent gets a
    /// meaningful `timeout` first.
    static let navigationDeadline: Duration = .seconds(28)
    static let waitPollInterval: Duration = .milliseconds(100)
    static let maxScreenshotWidth = 1_600
    static let maxFullPageHeight = 16_384.0
    static let dragSteps = 8
    /// WebKit's `_WKNavigationActionPolicyAllowWithoutTryingAppLink`
    /// (allow + 2): a plain `.allow` would hand a universal link to its app.
    static let allowWithoutAppLinks = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .cancel

    let webView: WKWebView

    private let allowsURL: (URL) -> Bool
    private let refusal: (URL) -> LeoBrowserError?
    private let clock: any Clock<Duration>
    private var generation = 0
    private var console = LeoIOSConsoleLog()
    private var navigations: [ObjectIdentifier: CheckedContinuation<Void, any Error>] = [:]
    private var lastTitle: (url: URL?, title: String)?
    private var titleObservation: NSKeyValueObservation?

    /// The user's own tap or key in the page.
    var onUserInput: (@MainActor () -> Void)?
    /// After the main frame commits a new document.
    var onCommit: (@MainActor () -> Void)?
    /// After the page's web content process stopped.
    var onContentProcessTerminate: (@MainActor () -> Void)?
    /// A navigation the page started was refused (a download, or a page on
    /// the agent's machine's localhost): the pane says why.
    var onRefusal: (@MainActor (LeoBrowserError) -> Void)?

    /// `refusal` names main-frame URLs that load but can't work here (the
    /// agent machine's localhost), with the error the agent and user see.
    init(
        configuration: WKWebViewConfiguration, allowsURL: @escaping (URL) -> Bool,
        refusal: @escaping (URL) -> LeoBrowserError? = { _ in nil }, clock: any Clock<Duration> = ContinuousClock()
    ) {
        let configuration = configuration.copy() as? WKWebViewConfiguration ?? configuration
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: LeoBrowserScripts.console, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: LeoBrowserScripts.userKeyInput, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.agentWorld))
        configuration.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.allowsURL = allowsURL
        self.refusal = refusal
        self.clock = clock
        super.init()
        let relay = LeoIOSWeakMessageHandler(self)
        controller.add(relay, contentWorld: .page, name: LeoBrowserScripts.consoleHandlerName)
        controller.add(relay, contentWorld: Self.agentWorld, name: LeoBrowserScripts.userInputHandlerName)
        webView.navigationDelegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(userTapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lastTitle = nil }
        }
    }

    @objc private func userTapped() { onUserInput?() }

    // MARK: Navigation

    private func navigate(_ start: () -> WKNavigation?) async throws {
        try await settle(start())
        let title = try? await run("return document.title", [:], in: Self.agentWorld) as? String
        lastTitle = (webView.url, title ?? webView.title ?? "")
    }

    /// Waits for `navigation` to finish, fail, time out or be cancelled.
    private func settle(_ navigation: WKNavigation?) async throws {
        guard let navigation else { return }
        let key = ObjectIdentifier(navigation)
        let timer = Task { [clock] in
            try await clock.sleep(for: Self.navigationDeadline)
            self.finish(key, .failure(LeoBrowserError(.timeout, "The page did not finish loading in time.")))
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

    // MARK: Scripts

    /// Runs `body` as an async function in `world`. Cancelling ends the call
    /// at once; WebKit's late answer, if any, is dropped (it never answers a
    /// script whose page navigated away).
    func run(_ body: String, _ arguments: [String: Any], in world: WKContentWorld) async throws -> Any? {
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
        return LeoBrowserError(.jsError, message)
    }

    /// Runs a ref script in Leo's world: `stale` answers throw `stale_ref`,
    /// `error` answers `invalid_args`.
    private func runOnRef(_ script: String, ref: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard Self.generation(of: ref) == generation else { throw LeoBrowserError.staleRef(ref) }
        let result = try await run(script, arguments.merging(["ref": ref]) { $1 }, in: Self.agentWorld) as? [String: Any]
        guard let result, result["stale"] == nil else { throw LeoBrowserError.staleRef(ref) }
        if let message = result["error"] as? String { throw LeoBrowserError(.invalidArgs, message) }
        return result
    }

    private func runOnRefs(_ script: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let result = try await run(script, arguments, in: Self.agentWorld) as? [String: Any]
        guard let result else { throw LeoBrowserError(.jsError, "The drag script returned nothing.") }
        if let ref = result["stale"] as? String { throw LeoBrowserError.staleRef(ref) }
        if let message = result["error"] as? String { throw LeoBrowserError(.invalidArgs, message) }
        return result
    }

    /// `s<gen>e<n>` → gen.
    private static func generation(of ref: String) -> Int? {
        guard ref.hasPrefix("s"), let e = ref.firstIndex(of: "e") else { return nil }
        return Int(ref[ref.index(after: ref.startIndex)..<e])
    }

    // MARK: Console

    /// Adds an entry as if the page had logged it, for what the browser
    /// refused to do for the page.
    func noteConsole(level: String, text: String) {
        console.append(level: level, text: text)
    }

    // MARK: Capture

    private var displayScale: Double { webView.traitCollection.displayScale > 0 ? webView.traitCollection.displayScale : 2 }

    private func viewportScreenshot() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: min(webView.bounds.width, Double(Self.maxScreenshotWidth) / displayScale))
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage else { throw LeoBrowserError(.jsError, "The screenshot had no bitmap.") }
        return try Self.png(cgImage, maxWidth: Self.maxScreenshotWidth)
    }

    /// The whole page from its PDF, which WebKit renders in full (a
    /// snapshot paints only what is on screen), stacked if WebKit split it.
    private func fullPageScreenshot() async throws -> Data {
        let height = try await run("return document.documentElement.scrollHeight", [:], in: Self.agentWorld) as? Double
        guard let height else { throw LeoBrowserError(.jsError, "Could not measure the page.") }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: min(height, Self.maxFullPageHeight) * webView.pageZoom)
        let data = try await pdf(configuration)
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw LeoBrowserError(.jsError, "Could not render the page.")
        }
        let pages = (0..<document.numberOfPages).compactMap { document.page(at: $0 + 1) }
        let boxes = pages.map { $0.getBoxRect(.mediaBox) }
        let width = boxes.map(\.width).max() ?? 0
        let total = min(boxes.reduce(0) { $0 + $1.height }, Self.maxFullPageHeight)
        guard width > 0, total > 0 else { throw LeoBrowserError(.jsError, "The page is empty.") }
        let scale = min(displayScale, Double(Self.maxScreenshotWidth) / width)
        guard let context = Self.bitmap(width: Int((width * scale).rounded(.down)), height: Int((total * scale).rounded())) else {
            throw LeoBrowserError(.jsError, "Could not render the page.")
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        var top = total
        for (page, box) in zip(pages, boxes) where top > 0 {
            context.saveGState()
            context.translateBy(x: -box.minX, y: top - box.maxY)
            context.drawPDFPage(page)
            context.restoreGState()
            top -= box.height
        }
        guard let image = context.makeImage() else { throw LeoBrowserError(.jsError, "Could not render the page.") }
        return try Self.png(image, maxWidth: Self.maxScreenshotWidth)
    }

    private func pdf(_ configuration: WKPDFConfiguration) async throws -> Data {
        do {
            return try await webView.pdf(configuration: configuration)
        } catch {
            throw LeoBrowserError(.jsError, "The PDF couldn’t be made: \(error.localizedDescription)")
        }
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// PNG of `source`, scaled down to at most `maxWidth` pixels wide.
    static func png(_ source: CGImage, maxWidth: Int) throws -> Data {
        let scale = min(1, Double(maxWidth) / Double(source.width))
        let width = Int((Double(source.width) * scale).rounded(.down))
        guard let context = bitmap(width: width, height: Int((Double(source.height) * scale).rounded())) else {
            throw LeoBrowserError(.jsError, "Could not scale the screenshot.")
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let data = NSMutableData()
        guard
            let scaled = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw LeoBrowserError(.jsError, "Could not encode the screenshot.") }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw LeoBrowserError(.jsError, "Could not encode the screenshot.") }
        return data as Data
    }
}

// MARK: - LeoBrowserPage

extension LeoIOSBrowserPage: LeoBrowserPage {
    var url: URL? { webView.url }

    /// The document's title from the last navigation waited for, until the
    /// web view's own title changes (it can lag `didFinish`).
    var title: String {
        if let lastTitle, lastTitle.url == webView.url { return lastTitle.title }
        return webView.title ?? ""
    }

    func load(_ url: URL) async throws {
        guard allowsURL(url) else {
            throw LeoBrowserError(.schemeNotAllowed, "Only http, https and about:blank pages can be opened, not \(url.scheme ?? "this URL").")
        }
        if let refused = refusal(url) { throw refused }
        try await navigate { webView.load(URLRequest(url: url)) }
    }

    func goBack() async throws {
        guard webView.canGoBack else { throw LeoBrowserError(.navigationFailed, "There is no previous page.") }
        try await navigate { webView.goBack() }
    }

    func goForward() async throws {
        guard webView.canGoForward else { throw LeoBrowserError(.navigationFailed, "There is no next page.") }
        try await navigate { webView.goForward() }
    }

    func reload() async throws { try await navigate { webView.reload() } }

    func snapshot() async throws -> String {
        generation += 1
        let arguments: [String: Any] = ["gen": generation, "limit": LeoBrowserScripts.snapshotLimit]
        guard
            let result = try await run(LeoBrowserScripts.snapshot, arguments, in: Self.agentWorld) as? [String: Any],
            let text = result["text"] as? String
        else { throw LeoBrowserError(.jsError, "The snapshot script returned nothing.") }
        return LeoBrowserScripts.snapshotText(text, truncated: result["truncated"] as? Bool ?? false)
    }

    func click(ref: String) async throws { _ = try await runOnRef(LeoBrowserScripts.tapRef, ref: ref) }

    func hover(ref: String) async throws { _ = try await runOnRef(LeoBrowserScripts.hoverRef, ref: ref) }

    func selectOption(ref: String, values: [String]) async throws -> [LeoBrowserSelectedOption] {
        let result = try await runOnRef(LeoBrowserScripts.selectOption, ref: ref, ["values": values])
        let selected = result["selected"] as? [[String: Any]] ?? []
        return selected.compactMap { entry in
            guard let value = entry["value"] as? String, let label = entry["label"] as? String else { return nil }
            return LeoBrowserSelectedOption(value: value, label: label)
        }
    }

    /// An HTML5-draggable source gets drag events; anything else a pointer
    /// drag, both as script events.
    func drag(startRef: String, endRef: String) async throws {
        for ref in [startRef, endRef] where Self.generation(of: ref) != generation { throw LeoBrowserError.staleRef(ref) }
        let refs: [String: Any] = ["startRef": startRef, "endRef": endRef]
        let source = try await runOnRefs(LeoBrowserScripts.dragSource, refs)
        guard let isHTML5 = source["html5"] as? Bool else { throw LeoBrowserError.staleRef(startRef) }
        guard startRef != endRef else { return }
        let script = isHTML5 ? LeoBrowserScripts.html5Drag : LeoBrowserScripts.pointerDragRefs
        _ = try await runOnRefs(script, refs.merging(["steps": Self.dragSteps]) { $1 })
    }

    func type(ref: String, text: String, submit: Bool) async throws {
        _ = try await runOnRef(LeoBrowserScripts.typeRef, ref: ref, ["text": text, "submit": submit])
    }

    func fileInput(ref: String) async throws -> LeoBrowserFileInput {
        let result = try await runOnRef(LeoBrowserScripts.fileInput, ref: ref)
        return LeoBrowserFileInput(allowsMultiple: result["multiple"] as? Bool ?? false)
    }

    func setFiles(ref: String, files: [LeoBrowserUploadFile]) async throws {
        let payload = files.map { ["name": $0.name, "type": $0.mimeType, "data": $0.data.base64EncodedString()] }
        _ = try await runOnRef(LeoBrowserScripts.setFiles, ref: ref, ["files": payload])
    }

    func press(_ combo: LeoBrowserKeyCombo) async throws {
        let modifiers = combo.modifiers
        let arguments: [String: Any] = [
            "key": combo.key, "shift": modifiers.contains(.shift), "ctrl": modifiers.contains(.control),
            "alt": modifiers.contains(.alt), "meta": modifiers.contains(.meta),
        ]
        _ = try await run(LeoBrowserScripts.pressKey, arguments, in: Self.agentWorld)
    }

    func screenshot(fullPage: Bool) async throws -> Data {
        fullPage ? try await fullPageScreenshot() : try await viewportScreenshot()
    }

    func pdf() async throws -> Data { try await pdf(WKPDFConfiguration()) }

    func waitForText(_ text: String, timeoutMilliseconds: Int) async throws {
        let limit = Duration.milliseconds(timeoutMilliseconds)
        let probe = "return !!document.body && document.body.innerText.includes(text)"
        var waited = Duration.zero
        while try await run(probe, ["text": text], in: Self.agentWorld) as? Bool != true {
            guard waited < limit else { throw LeoBrowserError(.timeout, "\"\(text)\" did not appear on the page.") }
            try await clock.sleep(for: Self.waitPollInterval)
            waited += Self.waitPollInterval
        }
    }

    /// As on the Mac: tried as an awaited expression, else run as the body
    /// of an async function.
    func evaluate(_ js: String) async throws -> String {
        var result = try await run(LeoBrowserScripts.evalExpression, ["js": js], in: .page)
        if (result as? [String: Any])?["csp"] != nil {
            result = try? await run(LeoBrowserScripts.evalExpressionDirect(js), [:], in: .page)
        }
        if let thrown = (result as? [String: Any])?["thrown"] as? String { throw LeoBrowserError(.jsError, thrown) }
        if let json = result as? String { return json }
        let body = "return JSON.stringify(await (async () => {\n\(js)\n})()) ?? 'null';"
        return try await run(body, [:], in: .page) as? String ?? "null"
    }

    func setUserAgent(_ userAgent: String?) { webView.customUserAgent = userAgent }

    func consoleMessages(since: Int?) -> LeoBrowserConsoleBatch { console.batch(since: since) }
}

// MARK: - WKNavigationDelegate

extension LeoIOSBrowserPage: WKNavigationDelegate {
    /// Downloads have nowhere to go on iPhone, and a page on the agent's
    /// machine's localhost can't load here: both are refused with the reason
    /// in the console (for the agent) and the pane (for the user).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isSubframe = navigationAction.targetFrame?.isMainFrame == false
        guard let url = navigationAction.request.url else { return .cancel }
        if navigationAction.shouldPerformDownload { return refuse(LeoIOSBrowserPage.noDownloads) }
        if isSubframe { return url.isFileURL ? .cancel : Self.allowWithoutAppLinks }
        guard allowsURL(url) else { return .cancel }
        if let refused = refusal(url) { return refuse(refused) }
        return Self.allowWithoutAppLinks
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.lowercased().hasPrefix("attachment")
        guard isAttachment || !navigationResponse.canShowMIMEType else { return .allow }
        refuse(LeoIOSBrowserPage.noDownloads)
        return .cancel
    }

    static let noDownloads = LeoBrowserError(.unsupported, "Downloads aren't supported in the agent browser on iPhone.")

    @discardableResult
    private func refuse(_ error: LeoBrowserError) -> WKNavigationActionPolicy {
        noteConsole(level: "error", text: "\(error.code.rawValue): \(error.message)")
        onRefusal?(error)
        return .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        generation += 1
        onCommit?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(ObjectIdentifier(navigation), .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(ObjectIdentifier(navigation), .failure(Self.navigationError(error)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(ObjectIdentifier(navigation), .failure(Self.navigationError(error)))
    }

    private static func navigationError(_ error: any Error) -> LeoBrowserError {
        LeoBrowserError(.navigationFailed, error.localizedDescription)
    }

    /// iOS stops a background app's web content processes freely: the page
    /// reloads where it was, and any wait on it fails now.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        for key in navigations.keys {
            finish(key, .failure(LeoBrowserError(.navigationFailed, "The page's web content process stopped.")))
        }
        onContentProcessTerminate?()
        webView.reload()
    }
}

// MARK: - Messages and taps

extension LeoIOSBrowserPage: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == LeoBrowserScripts.userInputHandlerName {
            // Only Leo's world can post here, and only for a trusted key.
            guard message.world == Self.agentWorld else { return }
            onUserInput?()
            return
        }
        guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
        let level = (body["level"] as? String).flatMap { LeoBrowserScripts.consoleLevels.contains($0) ? $0 : nil } ?? "log"
        noteConsole(level: level, text: text)
    }
}

extension LeoIOSBrowserPage: UIGestureRecognizerDelegate {
    /// The tap only listens: the page's own gestures run as they would.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// The page's console, capped in count and bytes like the Mac's.
struct LeoIOSConsoleLog {
    private struct Entry {
        let seq: Int
        let level: String
        let text: String
        var bytes: Int { level.utf8.count + text.utf8.count }
    }

    private var entries: [Entry] = []
    private var bytes = 0
    private var seq = 0
    private var cursor = 0

    mutating func append(level: String, text: String) {
        seq += 1
        let entry = Entry(seq: seq, level: level, text: LeoBrowserScripts.consoleText(text))
        entries.append(entry)
        bytes += entry.bytes
        while entries.count > LeoBrowserScripts.consoleCapacity || bytes > LeoBrowserScripts.consoleBufferLimit {
            bytes -= entries.removeFirst().bytes
        }
    }

    /// Messages after `since`, or after the last call's when nil.
    mutating func batch(since: Int?) -> LeoBrowserConsoleBatch {
        let found = entries.filter { $0.seq > (since ?? cursor) }
        cursor = max(cursor, found.last?.seq ?? 0)
        return LeoBrowserConsoleBatch(entries: found.map { LeoBrowserConsoleEntry(level: $0.level, text: $0.text) }, cursor: seq)
    }
}

/// Holds its target weakly: the content controller keeps its handlers
/// alive, and the page owns the controller.
@MainActor private final class LeoIOSWeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
