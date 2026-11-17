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
    let tabSet: LeoAgentBrowserTabs
    private let urlMapping: any LeoBrowserURLMapping
    private let uploads: LeoBrowserUploadReader
    private let filePicker: any LeoBrowserFilePicking
    private lazy var executor = LeoBrowserExecutor(tabs: tabSet, urlMapping: urlMapping, control: control, uploads: uploads)
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    private var stopPlacement: (() -> Void)?

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
            filePicker: filePicker, downloader: downloads ?? LeoWKBrowserDownloads(log: .withoutWorkspace()),
            toRemote: { [urlMapping] in urlMapping.toRemote($0) }
        )
        super.init()
        tabSet.onUserInput = { [weak self] in self?.control.send(.userInput) }
        tabSet.onChange = { [weak self] in self?.changed() }
        stopPlacement = viewHost.observePlacement { [weak self] in self?.tabSet.placementChanged() }
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
        stopPlacement?()
        stopPlacement = nil
        tabSet.closeAll()
        tabSet.downloader.cancelAll()
        filePicker.close()
        handlers = [:]
    }

    // MARK: - LeoAgentBrowserPaneSource

    var pendingPermission: LeoBrowserPermissionPrompt? { tabSet.pendingPermission }

    func answerPermission(_ prompt: LeoBrowserPermissionPrompt, allow: Bool) {
        tabSet.answerPermission(prompt, allow: allow)
    }

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

    var canReopenClosedTab: Bool {
        !tabSet.closedTabs.isEmpty && tabSet.tabs.count < LeoBrowserLimits.maximumTabs
    }

    func reopenClosedTab() -> Bool {
        guard canReopenClosedTab, let tab = tabSet.takeClosedTab() else { return false }
        Task { await reopen(tab) }
        return true
    }

    /// Opens `tab` again through the URL mapping, which reopens the port
    /// forward its page needed, as the address bar does.
    func reopen(_ tab: LeoClosedTab) async {
        guard let url = tab.url else { return }
        do {
            let local = try await urlMapping.toLocal(urlMapping.toRemote(url))
            _ = try await tabSet.openTab(url: local, userAgent: tab.userAgent, at: tab.index)
        } catch {
            Self.logger.error("reopen closed tab failed url=\(url.absoluteString, privacy: .private) error=\(String(describing: error), privacy: .public)")
        }
    }

    func history(_ direction: LeoBrowserHistoryDirection) -> [LeoBrowserHistoryEntry] {
        guard let list = tabSet.activePage?.webView.backForwardList else { return [] }
        let items = direction == .back ? list.backList.reversed() : Array(list.forwardList)
        return items.prefix(LeoBrowserHistoryEntry.menuLimit).enumerated().map { index, item in
            LeoBrowserHistoryEntry(
                offset: direction == .back ? -(index + 1) : index + 1,
                title: item.title ?? "", url: urlMapping.toRemote(item.url)
            )
        }
    }

    func goToHistory(_ entry: LeoBrowserHistoryEntry) -> Bool {
        guard let webView = tabSet.activePage?.webView,
              let item = webView.backForwardList.item(at: entry.offset),
              urlMapping.toRemote(item.url) == entry.url
        else { return false }
        webView.go(to: item)
        return true
    }

    /// The address the system's default browser can open for the active
    /// page (B-409): the one Leo itself loads, so a remote loopback page goes
    /// through its machine's forward on 127.0.0.1. The URL is checked again
    /// after mapping, since a page chose it. nil for no page or a blank tab.
    func externalURL() async throws -> URL? {
        guard let remote = activeRemoteURL, LeoBrowserURLPolicy.isExternallyOpenable(remote) else { return nil }
        let local = try await urlMapping.toLocal(remote)
        return LeoBrowserURLPolicy.isExternallyOpenable(local) ? local : nil
    }

    private(set) var isClearingSiteData = false

    /// Empties this agent's data store (B-409): every type WebKit keeps
    /// (cookies, caches, local and session storage, IndexedDB, service
    /// workers), whenever written. The store the tabs use, never one looked up
    /// again by name. Open pages stay as they are until they reload.
    func clearSiteData() async {
        isClearingSiteData = true
        defer { isClearingSiteData = false }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
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
/// the `WKUIDelegate` that turns a page's new windows into tabs and takes
/// its camera, microphone and location requests to the user (B-410).
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
    /// Maps a page's URL to the agent's (remote) terms, for what the user
    /// and the agent read about permission requests.
    private let toRemote: @MainActor (URL) -> URL
    private lazy var permissions = LeoBrowserPermissionDesk { [weak self] tab, request, denial in
        self?.note(denial, of: request, inTab: tab)
    }
    /// File choosers open per web view, answered when the tab closes.
    private var filePicks: [ObjectIdentifier: [LeoBrowserFilePick]] = [:]
    private var list: [Tab] = []
    /// Tabs closed since this browser opened, for ⌘⇧T. `closeAll` (the
    /// browser going away) leaves it alone: it goes with the browser.
    private(set) var closedTabs = LeoBrowserClosedTabs()
    private var activeID: Int?
    private var nextID = 1

    init(
        agentName: String, configuration: WKWebViewConfiguration, allowsURL: @escaping (URL) -> Bool,
        input: LeoSyntheticInput, viewHost: LeoAgentBrowserHost, filePicker: any LeoBrowserFilePicking,
        downloader: LeoWKBrowserDownloads, toRemote: @escaping @MainActor (URL) -> URL = { $0 }
    ) {
        self.agentName = agentName
        self.toRemote = toRemote
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
        list.map {
            LeoBrowserTabInfo(
                id: $0.id, url: $0.page.url, title: $0.page.title, isActive: $0.id == activeID,
                waitingPermission: permissions.waiting(inTab: $0.id)?.request
            )
        }
    }

    var downloads: [LeoBrowserDownload] { downloader.log.entries }

    func page(forTab id: Int?) -> (any LeoBrowserPage)? {
        list.first { $0.id == (id ?? activeID) }?.page
    }

    func openTab(url: URL, userAgent: String?) async throws -> Int {
        try await openTab(url: url, userAgent: userAgent, at: nil)
    }

    /// Opens a tab at `index` (clamped; the end when nil).
    func openTab(url: URL, userAgent: String?, at index: Int?) async throws -> Int {
        let tab = add(LeoWKBrowserPage(configuration: configuration, allowsURL: allowsURL, input: input), at: index)
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
        permissions.withdraw(exceptTab: activeID)
        onChange?()
    }

    func closeTab(_ id: Int) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let tab = list.remove(at: index)
        let override = tab.page.webView.customUserAgent
        closedTabs.record(LeoClosedTab(url: tab.page.url, index: index, userAgent: override?.isEmpty == false ? override : nil))
        if activeID == id { activeID = list.indices.contains(index) ? list[index].id : list.last?.id }
        tear(down: tab)
        permissions.withdraw(exceptTab: activeID)
        onChange?()
    }

    /// The most recently closed tab, removed from the stack.
    func takeClosedTab() -> LeoClosedTab? { closedTabs.popLast() }

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
        chooseFiles(
            for: webView, origin: LeoBrowserSite(frame.securityOrigin).label,
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

    /// A page asked for the camera, the microphone or both.
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        guard let kind = LeoBrowserPermissionKind(type) else { return decisionHandler(.deny) }
        requestPermission(for: webView, kind: kind, site: LeoBrowserSite(frame.securityOrigin)) { decisionHandler($0 ? .grant : .deny) }
    }

    /// A page asked for location. WebKit's public method from macOS 27 (the
    /// SDK we build with predates it, so it is declared by selector).
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        requestPermission(for: webView, kind: .location, site: LeoBrowserSite(frame.securityOrigin)) { decisionHandler($0 ? .grant : .deny) }
    }

    /// The same request on macOS 26 and earlier, where WebKit only calls
    /// its private twin. Without it those systems deny location silently.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func legacyWebView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        requestPermission(for: webView, kind: .location, site: LeoBrowserSite(frame.securityOrigin)) { decisionHandler($0 ? .grant : .deny) }
    }

    // MARK: - Permissions (B-410)

    /// A request from `webView`'s page: denied at once unless its tab is
    /// the active one and on screen, answered from the tab's earlier
    /// answers when it can be, else shown to the user. Never answered by
    /// an agent. `decide` runs exactly once.
    func requestPermission(
        for webView: WKWebView, kind: LeoBrowserPermissionKind, site: LeoBrowserSite, decide: @escaping @MainActor (Bool) -> Void
    ) {
        guard let tab = list.first(where: { $0.page.webView === webView }) else { return decide(false) }
        let isShown = tab.id == activeID && viewHost.isOnScreen(webView)
        let request = LeoBrowserPermissionRequest(kind: kind, site: site)
        if permissions.receive(request, inTab: tab.id, isShown: isShown, decide: decide) { onChange?() }
    }

    /// The active tab's ask waiting on the user, in remote terms.
    var pendingPermission: LeoBrowserPermissionPrompt? {
        guard let activeID, let ask = permissions.waiting(inTab: activeID) else { return nil }
        let request = LeoBrowserPermissionRequest(kind: ask.request.kind, site: remote(ask.request.site))
        return LeoBrowserPermissionPrompt(id: ask.id, agent: agentName, request: request)
    }

    /// The user's Allow or Don't Allow on `prompt`; nothing when it is no
    /// longer the ask shown. Not user input: it doesn't take control.
    func answerPermission(_ prompt: LeoBrowserPermissionPrompt, allow: Bool) {
        guard let activeID, permissions.answer(prompt.id, allow: allow, inTab: activeID) else { return }
        onChange?()
    }

    /// A page moved between a pane and the parking window: an ask whose
    /// page left the pane is withdrawn. A covered or minimised window keeps it.
    func placementChanged() {
        guard let activeID, let page = activePage, permissions.waiting(inTab: activeID) != nil,
              !viewHost.isInPane(page.webView) else { return }
        withdrawAsks(inTab: activeID, because: .paneHidden)
    }

    private func withdrawAsks(inTab tab: Int, because reason: LeoBrowserPermissionDenial.Withdrawal) {
        if permissions.withdraw(inTab: tab, because: reason) { onChange?() }
    }

    private func note(_ denial: LeoBrowserPermissionDenial, of request: LeoBrowserPermissionRequest, inTab tab: Int) {
        guard let page = list.first(where: { $0.id == tab })?.page else { return }
        let origin = remote(request.site).origin
        page.noteConsole(level: "error", text: LeoBrowserPermissionText.deniedLine(kind: request.kind, origin: origin, because: denial))
    }

    /// `site` in the agent's (remote) terms: a forwarded local port maps back.
    private func remote(_ site: LeoBrowserSite) -> LeoBrowserSite {
        site.url.map(toRemote).flatMap(LeoBrowserSite.init(url:)) ?? site
    }

    // MARK: - Helpers

    private func add(_ page: LeoWKBrowserPage, at index: Int? = nil) -> Tab {
        let id = nextID
        nextID += 1
        page.webView.uiDelegate = self
        page.webView.onUserInput = { [weak self] in self?.onUserInput?() }
        page.onDownload = { [weak self] in self?.downloader.adopt($0) }
        page.onCommit = { [weak self] in self?.withdrawAsks(inTab: id, because: .navigated) }
        page.onContentProcessTerminate = { [weak self] in self?.withdrawAsks(inTab: id, because: .pageStopped) }
        let notify: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } }
        let observations: [NSKeyValueObservation] = [
            page.webView.observe(\.url) { notify($0, $1) },
            page.webView.observe(\.title) { notify($0, $1) },
            page.webView.observe(\.isLoading) { notify($0, $1) },
            page.webView.observe(\.canGoBack) { notify($0, $1) },
            page.webView.observe(\.canGoForward) { notify($0, $1) },
        ]
        let tab = Tab(id: id, page: page, observations: observations)
        list.insert(tab, at: min(max(index ?? list.count, 0), list.count))
        activeID = id
        permissions.withdraw(exceptTab: activeID)
        viewHost.adopt(page.webView)
        onChange?()
        return tab
    }

    /// Closing a tab stops its downloads' fetch; a save under way finishes.
    private func tear(down tab: Tab) {
        tab.observations.forEach { $0.invalidate() }
        downloader.cancel(for: tab.page.webView)
        tab.page.onDownload = nil
        tab.page.onCommit = nil
        tab.page.onContentProcessTerminate = nil
        permissions.forget(tab: tab.id)
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
