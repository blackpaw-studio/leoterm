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
    private lazy var executor = LeoBrowserExecutor(tabs: tabSet, urlMapping: urlMapping, control: control)
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    /// `configuration` carries the agent's data store; each tab gets its own copy.
    init(
        key: LeoAgentBrowserKey, configuration: WKWebViewConfiguration, urlMapping: any LeoBrowserURLMapping,
        input: LeoSyntheticInput, viewHost: LeoAgentBrowserHost, allowsURL: @escaping (URL) -> Bool = LeoBrowserURLPolicy.allows
    ) {
        self.key = key
        self.urlMapping = urlMapping
        self.viewHost = viewHost
        tabSet = LeoAgentBrowserTabs(configuration: configuration, allowsURL: allowsURL, input: input, viewHost: viewHost)
        super.init()
        tabSet.onUserInput = { [weak self] in self?.control.send(.userInput) }
        tabSet.onChange = { [weak self] in self?.changed() }
    }

    var dataStore: WKWebsiteDataStore { tabSet.dataStore }

    // MARK: - LeoAgentBrowserModel

    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome {
        await executor.execute(tool: request.tool, args: request.args, requestID: request.id)
    }

    func openBlankTabIfEmpty() {
        if tabSet.tabs.isEmpty { openBlankTab() }
    }

    /// Closes every tab. The data store stays for the agent's next browser.
    func close() {
        tabSet.closeAll()
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
    private var list: [Tab] = []
    private var activeID: Int?
    private var nextID = 1

    init(configuration: WKWebViewConfiguration, allowsURL: @escaping (URL) -> Bool, input: LeoSyntheticInput, viewHost: LeoAgentBrowserHost) {
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

    func page(forTab id: Int?) -> (any LeoBrowserPage)? {
        list.first { $0.id == (id ?? activeID) }?.page
    }

    func openTab(url: URL) async throws -> Int {
        let tab = add(LeoWKBrowserPage(configuration: configuration, allowsURL: allowsURL, input: input))
        try await tab.page.load(url)
        return tab.id
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
        return add(LeoWKBrowserPage(configuration: configuration, allowsURL: allowsURL, input: input)).page.webView
    }

    /// `window.close()` from a page closes its tab.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = list.first(where: { $0.page.webView === webView }) else { return }
        closeTab(tab.id)
    }

    // MARK: - Helpers

    private func add(_ page: LeoWKBrowserPage) -> Tab {
        let id = nextID
        nextID += 1
        page.webView.uiDelegate = self
        page.webView.onUserInput = { [weak self] in self?.onUserInput?() }
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

    private func tear(down tab: Tab) {
        tab.observations.forEach { $0.invalidate() }
        tab.page.webView.uiDelegate = nil
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

    func make(_ key: LeoAgentBrowserKey) -> LeoAgentBrowser {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: LeoBrowserStoreID.identifier(machineID: machineID(key.host), agent: key.agent)
        )
        return LeoAgentBrowser(key: key, configuration: configuration, urlMapping: urlMapping(key), input: input, viewHost: viewHost)
    }
}
