import LeoKit
import OSLog
import UIKit
import WebKit

/// One agent's browser on iPhone (B-305): up to `LeoBrowserLimits.maximumTabs`
/// tabs sharing the agent's own persistent data store (named for its
/// machine and agent, as on the Mac), the control state the user and the
/// agent share, and the executor that runs the agent's browser tools here.
///
/// What differs from the Mac: the agent's machine's localhost can't be
/// reached, so those URLs are refused with a plain reason; there is no
/// workspace, so downloads, uploads and saved captures are `unsupported`.
@MainActor final class LeoIOSAgentBrowser: NSObject, LeoAgentBrowserRunning {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.ios", category: "AgentBrowser")

    let key: LeoAgentBrowserKey
    let machineName: String
    let control = LeoBrowserControlModel()
    let tabSet: LeoIOSBrowserTabs
    let viewHost: LeoIOSBrowserParking
    private let urlMapping: LeoLoopbackRefusingURLMapping
    private lazy var executor = LeoBrowserExecutor(tabs: tabSet, urlMapping: urlMapping, control: control, canSaveToWorkspace: false)
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    private var stopControl: (() -> Void)?
    /// What the pane last refused to load, until the next navigation.
    private(set) var refusal: LeoBrowserError?
    private(set) var isClearingSiteData = false

    /// `allowsURL` is the scheme rule for every load (tests widen it to
    /// serve fixture pages).
    init(
        key: LeoAgentBrowserKey, machineName: String, configuration: WKWebViewConfiguration, viewHost: LeoIOSBrowserParking,
        allowsURL: @escaping (URL) -> Bool = LeoBrowserURLPolicy.allows
    ) {
        self.key = key
        self.machineName = machineName
        self.viewHost = viewHost
        let urlMapping = LeoLoopbackRefusingURLMapping(machine: machineName)
        self.urlMapping = urlMapping
        tabSet = LeoIOSBrowserTabs(
            agentName: key.agent, configuration: configuration, viewHost: viewHost, allowsURL: allowsURL,
            refusal: { url in
                guard LeoBrowserLoopback.isMachineLocal(url) else { return nil }
                return LeoBrowserError(.localhostUnreachable, LeoBrowserLoopback.unreachableMessage(machine: machineName))
            }
        )
        super.init()
        tabSet.onUserInput = { [weak self] in self?.control.send(.userInput) }
        tabSet.onChange = { [weak self] in self?.changed() }
        tabSet.onRefusal = { [weak self] in
            self?.refusal = $0
            self?.changed()
        }
        stopControl = control.observe { [weak self] _ in self?.changed() }
    }

    /// The store for `key` on `daemonID`, as the Mac names it.
    static func configuration(daemonID: String, agent: String) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: LeoBrowserStoreID.identifier(machineID: daemonID, agent: agent))
        configuration.allowsInlineMediaPlayback = true
        return configuration
    }

    var dataStore: WKWebsiteDataStore { tabSet.dataStore }

    // MARK: - LeoAgentBrowserRunning

    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome {
        await executor.execute(tool: request.tool, args: request.args, requestID: request.id)
    }

    /// The pane's own blank tab when it opens on nothing; it isn't the user
    /// acting, so the agent keeps driving.
    func openBlankTabIfEmpty() {
        guard tabSet.tabs.isEmpty else { return }
        Task { _ = try? await tabSet.openTab(url: LeoIOSBrowserTabs.blank) }
    }

    /// Closes every tab. The data store stays for the agent's next browser.
    func close() {
        stopControl?()
        stopControl = nil
        tabSet.closeAll()
        handlers = [:]
    }

    // MARK: - The pane

    var activeWebView: WKWebView? { tabSet.activePage?.webView }
    var activeURL: URL? { tabSet.activePage?.url }
    var isLoading: Bool { activeWebView?.isLoading ?? false }
    var canGoBack: Bool { activeWebView?.canGoBack ?? false }
    var canGoForward: Bool { activeWebView?.canGoForward ?? false }

    func goBack() { userNavigation { $0.goBack() } }
    func goForward() { userNavigation { $0.goForward() } }
    func reload() { userNavigation { $0.reload() } }

    /// The user acting in the pane takes control, as on the Mac.
    private func act() { control.send(.userInput) }

    /// The user's own navigations dismiss the active tab's dialog first (B-412).
    private func userNavigation(_ go: (WKWebView) -> WKNavigation?) {
        act()
        tabSet.withdrawActiveDialog()
        refusal = nil
        guard let webView = activeWebView else { return }
        _ = go(webView)
        changed()
    }

    static let invalidAddressMessage = "Enter a web address such as example.com or https://example.com"

    /// Loads the address the user typed (https:// is assumed). A page on
    /// the agent machine's localhost is refused with the reason in the pane.
    func navigate(to text: String) {
        guard let url = Self.url(fromAddress: text) else {
            refusal = LeoBrowserError(.invalidArgs, Self.invalidAddressMessage)
            return changed()
        }
        navigate(to: url)
    }

    /// `text` as a page address: https:// when it names no scheme (http://
    /// for a localhost form, so its refusal names the right page).
    static func url(fromAddress text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let hasScheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:(//|blank$)"#, options: .regularExpression) != nil
        if hasScheme { return try? LeoBrowserURLPolicy.validate(text) }
        let candidate = URL(string: "https://\(text)").map { LeoBrowserLoopback.isMachineLocal($0) ? "http://\(text)" : "https://\(text)" }
        return candidate.flatMap { try? LeoBrowserURLPolicy.validate($0) }
    }

    func navigate(to url: URL) {
        act()
        tabSet.withdrawActiveDialog()
        refusal = nil
        Task {
            do {
                let local = try await urlMapping.toLocal(url)
                if let webView = activeWebView {
                    webView.load(URLRequest(url: local))
                } else {
                    _ = try await tabSet.openTab(url: local)
                }
            } catch let error as LeoBrowserError {
                refusal = error
            } catch {
                Self.logger.error("address bar load failed error=\(String(describing: error), privacy: .public)")
            }
            changed()
        }
    }

    func openBlankTab() {
        guard tabSet.tabs.count < LeoBrowserLimits.maximumTabs else { return }
        act()
        Task { _ = try? await tabSet.openTab(url: LeoIOSBrowserTabs.blank) }
    }

    func selectTab(_ id: Int) {
        act()
        tabSet.selectTab(id)
    }

    func closeTab(_ id: Int) {
        act()
        tabSet.closeTab(id)
    }

    var canReopenClosedTab: Bool { !tabSet.closedTabs.isEmpty && tabSet.tabs.count < LeoBrowserLimits.maximumTabs }

    func reopenClosedTab() {
        guard canReopenClosedTab, let tab = tabSet.takeClosedTab(), let url = tab.url else { return }
        act()
        Task {
            do {
                _ = try await tabSet.openTab(url: try await urlMapping.toLocal(url), userAgent: tab.userAgent, at: tab.index)
            } catch {
                Self.logger.error("reopen closed tab failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The back or forward list, nearest first, for the buttons' menus.
    func history(back: Bool) -> [WKBackForwardListItem] {
        guard let list = activeWebView?.backForwardList else { return [] }
        let items = back ? Array(list.backList.reversed()) : list.forwardList
        return Array(items.prefix(Self.historyMenuLimit))
    }

    static let historyMenuLimit = 15

    func go(to item: WKBackForwardListItem) { userNavigation { $0.go(to: item) } }

    /// Safari can open the active page unless it is blank, not http(s), or
    /// on the agent machine's localhost.
    var externalURL: URL? {
        guard let url = activeURL, LeoBrowserURLPolicy.isExternallyOpenable(url), !LeoBrowserLoopback.isMachineLocal(url) else { return nil }
        return url
    }

    /// Empties this agent's data store only (D-887): every WebKit data type,
    /// whenever written. Open pages stay until they reload.
    func clearSiteData() async {
        isClearingSiteData = true
        changed()
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        isClearingSiteData = false
        changed()
    }

    var pendingPermission: LeoBrowserPermissionPrompt? { tabSet.pendingPermission }
    func answerPermission(_ prompt: LeoBrowserPermissionPrompt, allow: Bool) { tabSet.answerPermission(prompt, allow: allow) }
    var pendingDialog: LeoBrowserDialogPrompt? { tabSet.pendingDialog }
    func answerDialog(_ prompt: LeoBrowserDialogPrompt, accept: Bool, text: String?) { tabSet.answerDialog(prompt, accept: accept, text: text) }

    /// The pane stopped showing this browser, or the app left the foreground.
    func paneHidden() { tabSet.paneHidden() }

    func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    private func changed() {
        handlers.values.forEach { $0() }
    }
}

/// Where every agent-browser web view lives while no pane shows it: a lot
/// off the side of the app's window, so WebKit keeps the page running (a
/// web view outside any window is suspended) and the agent can keep
/// driving it. The pane borrows the active one while it shows.
@MainActor final class LeoIOSBrowserParking {
    private let window: () -> UIWindow?
    private weak var lot: UIView?
    private weak var stage: UIView?

    init(window: @escaping () -> UIWindow?) {
        self.window = window
    }

    /// Puts `webView` in the lot, at the size it would have on screen.
    func park(_ webView: WKWebView) {
        guard let lot = lot ?? makeLot() else { return }
        guard webView.superview !== lot else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = lot.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lot.addSubview(webView)
    }

    /// Shows `webView` filling `stage`, parking whatever the stage showed.
    func show(_ webView: WKWebView, on stage: UIView) {
        for case let shown as WKWebView in stage.subviews where shown !== webView { park(shown) }
        self.stage = stage
        guard webView.superview !== stage else { return }
        webView.removeFromSuperview()
        webView.frame = stage.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stage.addSubview(webView)
    }

    /// Parks everything `stage` shows; the pane is going away.
    func clear(_ stage: UIView) {
        for case let shown as WKWebView in stage.subviews { park(shown) }
        if self.stage === stage { self.stage = nil }
    }

    /// Whether the user can see `webView` now (D-892).
    func isShown(_ webView: WKWebView) -> Bool {
        guard let stage, webView.superview === stage, let window = stage.window else { return false }
        return window.windowScene?.activationState == .foregroundActive
    }

    private func makeLot() -> UIView? {
        guard let window = window() else { return nil }
        let size = window.bounds.size
        let lot = UIView(frame: CGRect(origin: CGPoint(x: -size.width - 1_000, y: 0), size: size))
        lot.isUserInteractionEnabled = false
        lot.accessibilityElementsHidden = true
        lot.autoresizingMask = [.flexibleHeight]
        window.insertSubview(lot, at: 0)
        self.lot = lot
        return lot
    }
}
