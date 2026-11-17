import AppKit
import LeoKit
import OSLog
import WebKit

/// One agent's browser on one machine (C5): up to `LeoBrowserLimits.maximumTabs`
/// tabs sharing the agent's own persistent data store, the control state
/// the user and the agent share, and the executor that runs the agent's
/// browser tools against it. Links that open a window (`target=_blank`,
/// `window.open`) land as tabs here.
///
/// Every tab's web view lives where `viewHost` puts it: parked off screen
/// from the moment it is made, in a pane while one shows it.
@available(macOS 14, *)
@MainActor final class LeoAgentBrowser: NSObject, LeoAgentBrowserModel {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "AgentBrowser")

    let key: LeoAgentBrowserKey
    let control = LeoBrowserControlModel()
    let viewHost: LeoAgentBrowserHost
    private let tabSet: LeoAgentBrowserTabs
    private let urlMapping: any LeoBrowserURLMapping
    private let uploads: LeoBrowserUploadReader
    private let filePicker: any LeoBrowserFilePicking
    private lazy var executor = LeoBrowserExecutor(tabs: tabSet, urlMapping: urlMapping, control: control, uploads: uploads)
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    /// `configuration` carries the agent's data store; each tab gets its own copy.
    /// `downloads` saves finished downloads into the agent's workspace; by
    /// default there is none, so a download fails plainly. `uploads` reads
    /// the workspace files `browser_upload` names; by default there is none.
    init(
        key: LeoAgentBrowserKey, configuration: WKWebViewConfiguration, urlMapping: any LeoBrowserURLMapping,
        input: LeoSyntheticInput, viewHost: LeoAgentBrowserHost, allowsURL: @escaping (URL) -> Bool = LeoBrowserURLPolicy.allows,
        filePicker: (any LeoBrowserFilePicking)? = nil, downloads: LeoWKBrowserDownloads? = nil,
        uploads: LeoBrowserUploadReader = .noWorkspace
    ) {
        self.key = key
        self.uploads = uploads
        self.urlMapping = urlMapping
        self.viewHost = viewHost
        let filePicker = filePicker ?? LeoOpenPanelFilePicker()
        self.filePicker = filePicker
        tabSet = LeoAgentBrowserTabs(
            agentName: key.agent, configuration: configuration, allowsURL: allowsURL, input: input, viewHost: viewHost,
            filePicker: filePicker, downloader: downloads ?? LeoWKBrowserDownloads(log: .withoutWorkspace())
        )
        super.init()
        tabSet.onUserInput = { [weak self] in self?.control.send(.userInput) }
        tabSet.onChange = { [weak self] in self?.changed() }
    }

    var dataStore: WKWebsiteDataStore { tabSet.dataStore }

    /// This session's downloads, for the pane's strip.
    var downloads: LeoBrowserDownloads { tabSet.downloader.log }

    // MARK: - LeoAgentBrowserModel

    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome {
        await executor.execute(tool: request.tool, args: request.args, requestID: request.id)
    }

    func openBlankTabIfEmpty() {
        if tabSet.tabs.isEmpty { openBlankTab() }
    }

    /// Closes every tab, stopping downloads still fetching and dismissing
    /// file choosers, then removes the local copies of files chosen for
    /// upload. The data store stays for the agent's next browser.
    func close() {
        tabSet.closeAll()
        tabSet.downloader.cancelAll()
        filePicker.close()
        handlers = [:]
    }

    // MARK: - LeoAgentBrowserPaneSource

    var tabs: any LeoBrowserTabs { tabSet }
    var activeView: NSView? { tabSet.activePage?.webView }
    var activeRemoteURL: URL? { tabSet.activePage?.url.map(urlMapping.toRemote) }
    var isLoading: Bool { tabSet.activePage?.webView.isLoading ?? false }
    var canGoBack: Bool { tabSet.activePage?.webView.canGoBack ?? false }
    var canGoForward: Bool { tabSet.activePage?.webView.canGoForward ?? false }

    func goBack() { tabSet.activePage?.webView.goBack() }
    func goForward() { tabSet.activePage?.webView.goForward() }
    func reload() { tabSet.activePage?.webView.reload() }

    func navigate(to url: URL) {
        Task {
            do {
                let local = try await urlMapping.toLocal(url)
                if let page = tabSet.activePage {
                    page.webView.load(URLRequest(url: local))
                } else {
                    _ = try await tabSet.openTab(url: local)
                }
            } catch {
                Self.logger.error("address bar load failed url=\(url.absoluteString, privacy: .private) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func openBlankTab() {
        guard tabSet.tabs.count < LeoBrowserLimits.maximumTabs else { return NSSound.beep() }
        Task { _ = try? await tabSet.openTab(url: LeoAgentBrowserTabs.blank) }
    }

    func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    private func changed() {
        viewHost.refresh(self)
        handlers.values.forEach { $0() }
    }
}

/// An agent browser's tabs: the `LeoBrowserTabs` the executor drives, and
/// the `WKUIDelegate` that turns a page's new windows into tabs.
@available(macOS 14, *)
@MainActor final class LeoAgentBrowserTabs: NSObject, LeoBrowserTabs, WKUIDelegate {
    static let blank = URL(string: "about:blank")!

    private struct Tab {
        let id: Int
        let page: LeoWKBrowserPage
        let observations: [NSKeyValueObservation]
    }

    /// The user's own input in any tab.
    var onUserInput: (@MainActor () -> Void)?
    /// After any change to the tabs, the active tab, or a tab's URL, title,
    /// loading or history.
    var onChange: (@MainActor () -> Void)?

    private let configuration: WKWebViewConfiguration
    private let allowsURL: (URL) -> Bool
    private let input: LeoSyntheticInput
    private let viewHost: LeoAgentBrowserHost
    private let agentName: String
    private let filePicker: any LeoBrowserFilePicking
    let downloader: LeoWKBrowserDownloads
    /// File choosers open per web view, answered when the tab closes.
    private var filePicks: [ObjectIdentifier: [LeoBrowserFilePick]] = [:]
    private var list: [Tab] = []
    private var activeID: Int?
    private var nextID = 1

    init(
        agentName: String, configuration: WKWebViewConfiguration, allowsURL: @escaping (URL) -> Bool,
        input: LeoSyntheticInput, viewHost: LeoAgentBrowserHost, filePicker: any LeoBrowserFilePicking,
        downloader: LeoWKBrowserDownloads
    ) {
        self.agentName = agentName
        self.filePicker = filePicker
        self.downloader = downloader
        self.configuration = configuration
        self.allowsURL = allowsURL
        self.input = input
        self.viewHost = viewHost
    }

    var dataStore: WKWebsiteDataStore { configuration.websiteDataStore }

    var activePage: LeoWKBrowserPage? { list.first { $0.id == activeID }?.page }

    // MARK: - LeoBrowserTabs

    var tabs: [LeoBrowserTabInfo] {
        list.map { LeoBrowserTabInfo(id: $0.id, url: $0.page.url, title: $0.page.title, isActive: $0.id == activeID) }
    }

    var downloads: [LeoBrowserDownload] { downloader.log.entries }

    func page(forTab id: Int?) -> (any LeoBrowserPage)? {
        list.first { $0.id == (id ?? activeID) }?.page
    }

    func openTab(url: URL, userAgent: String?) async throws -> Int {
        let tab = add(LeoWKBrowserPage(configuration: configuration, allowsURL: allowsURL, input: input))
        tab.page.setUserAgent(userAgent)
        try await tab.page.load(url)
        return tab.id
    }

    func saveCapture(_ data: Data, kind: LeoBrowserCaptureKind, path: String?, defaultName: String) async throws -> LeoBrowserSavedDownload {
        try await downloader.log.saveCapture(data, kind: kind, path: path, defaultName: defaultName)
    }

    func selectTab(_ id: Int) {
        guard activeID != id, list.contains(where: { $0.id == id }) else { return }
        activeID = id
        onChange?()
    }

    func closeTab(_ id: Int) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let tab = list.remove(at: index)
        if activeID == id { activeID = list.indices.contains(index) ? list[index].id : list.last?.id }
        tear(down: tab)
        onChange?()
    }

    func closeAll() {
        let closing = list
        list = []
        activeID = nil
        closing.forEach(tear(down:))
        onChange?()
    }

    // MARK: - WKUIDelegate

    /// A page opened a window: it becomes a new active tab, unless the
    /// browser is full, when the opener's console says why.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard list.count < LeoBrowserLimits.maximumTabs else {
            let opener = list.first { $0.page.webView === webView }?.page
            opener?.noteConsole(level: "error", text: "tab_limit: \(LeoBrowserError.tabLimit(LeoBrowserLimits.maximumTabs).message); a new window was not opened")
            return nil
        }
        let popup = add(LeoWKBrowserPage(configuration: configuration, allowsURL: allowsURL, input: input))
        // An empty `customUserAgent` means "no override"; copy only a real one.
        let openerOverride = list.first { $0.page.webView === webView }?.page.webView.customUserAgent
        popup.page.setUserAgent(openerOverride.flatMap { $0.isEmpty ? nil : $0 })
        return popup.page.webView
    }

    /// `window.close()` from a page closes its tab.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = list.first(where: { $0.page.webView === webView }) else { return }
        closeTab(tab.id)
    }

    /// A page's `<input type=file>` was clicked.
    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let origin = frame.securityOrigin
        chooseFiles(
            for: webView, origin: LeoBrowserFilePickRequest.originLabel(host: origin.host, port: origin.port),
            allowsMultipleSelection: parameters.allowsMultipleSelection,
            allowsDirectories: parameters.allowsDirectories, completion: completionHandler
        )
    }

    /// Shows the chooser for `webView`. `completion` runs exactly once.
    func chooseFiles(
        for webView: WKWebView, origin: String, allowsMultipleSelection: Bool, allowsDirectories: Bool,
        completion: @escaping @MainActor ([URL]?) -> Void
    ) {
        let key = ObjectIdentifier(webView)
        guard list.contains(where: { $0.page.webView === webView }) else { return completion(nil) }
        let pick = LeoBrowserFilePick { [weak self] urls in
            self?.filePicks[key]?.removeAll { $0.isFinished }
            completion(urls)
        }
        filePicks[key, default: []].append(pick)
        let request = LeoBrowserFilePickRequest(
            agent: agentName, origin: origin,
            allowsMultipleSelection: allowsMultipleSelection, allowsDirectories: allowsDirectories
        )
        pick.attach(filePicker.present(request, completion: { pick.finish($0) }))
    }

    // MARK: - Helpers

    private func add(_ page: LeoWKBrowserPage) -> Tab {
        let id = nextID
        nextID += 1
        page.webView.uiDelegate = self
        page.webView.onUserInput = { [weak self] in self?.onUserInput?() }
        page.onDownload = { [weak self] in self?.downloader.adopt($0) }
        let notify: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } }
        let observations: [NSKeyValueObservation] = [
            page.webView.observe(\.url) { notify($0, $1) },
            page.webView.observe(\.title) { notify($0, $1) },
            page.webView.observe(\.isLoading) { notify($0, $1) },
            page.webView.observe(\.canGoBack) { notify($0, $1) },
            page.webView.observe(\.canGoForward) { notify($0, $1) },
        ]
        let tab = Tab(id: id, page: page, observations: observations)
        list.append(tab)
        activeID = id
        viewHost.adopt(page.webView)
        onChange?()
        return tab
    }

    /// Closing a tab stops its downloads' fetch; a save under way finishes.
    private func tear(down tab: Tab) {
        tab.observations.forEach { $0.invalidate() }
        downloader.cancel(for: tab.page.webView)
        tab.page.onDownload = nil
        tab.page.webView.uiDelegate = nil
        filePicks.removeValue(forKey: ObjectIdentifier(tab.page.webView))?.forEach { $0.abandon() }
        tab.page.webView.onUserInput = nil
        tab.page.webView.stopLoading()
        viewHost.release(tab.page.webView)
    }
}

/// Makes agent browsers the way the app does: each on the store named for
/// its machine and agent, with its machine's URL mapping.
@available(macOS 14, *)
@MainActor struct LeoAgentBrowserFactory {
    /// A stable id for the machine a browser runs on, for its store's name.
    let machineID: (LeoHostID) -> String
    let urlMapping: (LeoAgentBrowserKey) -> any LeoBrowserURLMapping
    let input: LeoSyntheticInput
    let viewHost: LeoAgentBrowserHost
    /// The `Version/x Safari/…` tail of the user agent; sites that gate on
    /// the Safari version (chase.com) reject a bare WebKit one.
    var userAgentApplicationName: String = LeoBrowserUserAgent.applicationName()
    /// Each browser's download log: where its downloads are saved.
    var makeDownloads: (LeoAgentBrowserKey) -> LeoBrowserDownloads = { _ in .withoutWorkspace() }
    /// Where each browser's `browser_upload` reads files from.
    var makeUploads: (LeoAgentBrowserKey) -> LeoBrowserUploadReader = { _ in .noWorkspace }
    /// Each browser's chooser for a page's `<input type=file>`; nil for the Mac's open panel.
    var makeFilePicker: (LeoAgentBrowserKey) -> (any LeoBrowserFilePicking)? = { _ in nil }

    func make(_ key: LeoAgentBrowserKey) -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = userAgentApplicationName
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: LeoBrowserStoreID.identifier(machineID: machineID(key.host), agent: key.agent)
        )
        return LeoAgentBrowser(
            key: key, configuration: configuration, urlMapping: urlMapping(key), input: input, viewHost: viewHost,
            filePicker: makeFilePicker(key), downloads: LeoWKBrowserDownloads(log: makeDownloads(key)), uploads: makeUploads(key)
        )
    }
}

extension LeoBrowserDownloads {
    /// A log for a browser with nowhere to save: every finished download
    /// fails plainly with "no workspace".
    static func withoutWorkspace() -> LeoBrowserDownloads {
        LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { nil })
    }
}
