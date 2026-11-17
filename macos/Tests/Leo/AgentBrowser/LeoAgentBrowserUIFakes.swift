import AppKit
import Foundation
import LeoKit

@testable import Ghostty

/// A tab set for UI tests: no pages, or one active page when set.
@MainActor final class FakeBrowserTabs: LeoBrowserTabs {
    var tabs: [LeoBrowserTabInfo] = []
    var downloads: [LeoBrowserDownload] = []
    /// What `page(forTab: nil)` returns.
    var activePage: (any LeoBrowserPage)?
    private(set) var opened: [URL] = []
    private(set) var selected: [Int] = []
    private(set) var closed: [Int] = []

    func page(forTab id: Int?) -> (any LeoBrowserPage)? { id == nil ? activePage : nil }

    func openTab(url: URL, userAgent: String?) async throws -> Int {
        opened.append(url)
        return 1
    }

    func saveCapture(_ data: Data, kind: LeoBrowserCaptureKind, path: String?, defaultName: String) async throws -> LeoBrowserSavedDownload {
        throw LeoBrowserError(.saveFailed, "FakeBrowserTabs saves nothing.")
    }

    func selectTab(_ id: Int) { selected.append(id) }
    func closeTab(_ id: Int) { closed.append(id) }
}

/// A scriptable pane source: tests set its state and call `changed()`.
@MainActor final class FakePaneSource: LeoAgentBrowserPaneSource {
    let fakeTabs = FakeBrowserTabs()
    let control = LeoBrowserControlModel()
    let viewHost: LeoAgentBrowserHost
    /// Set before making a model: it observes the log it finds.
    var downloads = LeoBrowserDownloads.withoutWorkspace()
    var tabs: any LeoBrowserTabs { fakeTabs }
    var activeView: NSView?
    var activeRemoteURL: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    private(set) var calls: [String] = []
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    init(viewHost: LeoAgentBrowserHost? = nil) {
        self.viewHost = viewHost ?? LeoAgentBrowserHost()
    }

    func goBack() { calls.append("back") }
    func goForward() { calls.append("forward") }
    func reload() { calls.append("reload") }
    func navigate(to url: URL) { calls.append("navigate \(url.absoluteString)") }
    func openBlankTab() { calls.append("newTab") }

    var canReopenClosedTab = false
    /// What `history(_:)` lists, by direction.
    var fakeHistory: [LeoBrowserHistoryDirection: [LeoBrowserHistoryEntry]] = [:]
    /// Whether `goToHistory` finds its entry still current.
    var historyJumpSucceeds = true

    func reopenClosedTab() -> Bool {
        guard canReopenClosedTab else { return false }
        calls.append("reopenClosedTab")
        return true
    }

    func history(_ direction: LeoBrowserHistoryDirection) -> [LeoBrowserHistoryEntry] { fakeHistory[direction] ?? [] }

    func goToHistory(_ entry: LeoBrowserHistoryEntry) -> Bool {
        calls.append("history \(entry.offset)")
        return historyJumpSucceeds
    }

    var pendingPermission: LeoBrowserPermissionPrompt?

    func answerPermission(_ prompt: LeoBrowserPermissionPrompt, allow: Bool) {
        calls.append("permission \(prompt.id) \(allow ? "allow" : "deny")")
    }

    var key = LeoAgentBrowserKey(host: .local, agent: "alpha")
    /// What `externalURL()` gives, or throws.
    var externalURLResult: Result<URL?, any Error> = .success(nil)
    var isClearingSiteData = false

    func externalURL() async throws -> URL? { try externalURLResult.get() }
    func clearSiteData() async { calls.append("clearSiteData") }

    func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    func changed() { handlers.values.forEach { $0() } }
}

@MainActor final class FakePresence: LeoAgentBrowserPresence {
    private var browsers: [LeoAgentBrowserKey: FakePaneSource] = [:]
    private var handlers: [UUID: @MainActor (LeoAgentBrowserPresenceChange) -> Void] = [:]
    private(set) var closeRequests: [LeoAgentBrowserKey] = []
    private(set) var openRequests: [LeoAgentBrowserKey] = []

    var keys: Set<LeoAgentBrowserKey> { Set(browsers.keys) }
    func browser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)? { browsers[key] }

    /// False stands for a Mac that can't run the browser.
    var canOpen = true

    func openBrowser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)? {
        openRequests.append(key)
        return canOpen ? open(key) : nil
    }

    @discardableResult
    func open(_ key: LeoAgentBrowserKey) -> FakePaneSource {
        if let existing = browsers[key] { return existing }
        let source = FakePaneSource()
        browsers[key] = source
        handlers.values.forEach { $0(.opened(key)) }
        return source
    }

    func closeBrowser(for key: LeoAgentBrowserKey) {
        closeRequests.append(key)
        remove(key)
    }

    /// The agent stopped: the browser goes without a close request.
    func remove(_ key: LeoAgentBrowserKey) {
        guard browsers.removeValue(forKey: key) != nil else { return }
        handlers.values.forEach { $0(.closed(key)) }
    }

    func observe(_ handler: @escaping @MainActor (LeoAgentBrowserPresenceChange) -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }
}

/// Lets what the main queue already holds run -- the panes refresh there
/// after a model change -- without waiting on a clock.
@MainActor func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// A page that only answers what the pane reads and saves: its address,
/// title and captures. Anything that drives it fails.
@MainActor final class FakeCapturePage: LeoBrowserPage {
    var url: URL?
    var title: String
    var pdfData = Data("%PDF-fake".utf8)
    var screenshotData = Data([0x89, 0x50, 0x4E, 0x47])
    private(set) var captures: [String] = []

    init(url: URL?, title: String) {
        self.url = url
        self.title = title
    }

    func pdf() async throws -> Data {
        captures.append("pdf")
        return pdfData
    }

    func screenshot(fullPage: Bool) async throws -> Data {
        captures.append("screenshot full=\(fullPage)")
        return screenshotData
    }

    private static let unused = LeoBrowserError(.jsError, "FakeCapturePage only captures")
    func load(_ url: URL) async throws { throw Self.unused }
    func goBack() async throws { throw Self.unused }
    func goForward() async throws { throw Self.unused }
    func reload() async throws { throw Self.unused }
    func snapshot() async throws -> String { throw Self.unused }
    func click(ref: String) async throws { throw Self.unused }
    func type(ref: String, text: String, submit: Bool) async throws { throw Self.unused }
    func fileInput(ref: String) async throws -> LeoBrowserFileInput { throw Self.unused }
    func setFiles(ref: String, files: [LeoBrowserUploadFile]) async throws { throw Self.unused }
    func press(_ combo: LeoBrowserKeyCombo) async throws { throw Self.unused }
    func waitForText(_ text: String, timeoutMilliseconds: Int) async throws { throw Self.unused }
    func evaluate(_ js: String) async throws -> String { throw Self.unused }
    func setUserAgent(_ userAgent: String?) {}
    func consoleMessages(since: Int?) -> LeoBrowserConsoleBatch { LeoBrowserConsoleBatch(entries: [], cursor: 0) }
}
