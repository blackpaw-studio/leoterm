import LeoKit
import UIKit
import WebKit

/// An agent browser's tabs on iPhone (B-305): the `LeoBrowserTabs` the
/// executor drives, and the `WKUIDelegate` that turns a page's new windows
/// into tabs, puts its JavaScript dialogs on the dialog desk (B-412) and
/// takes its camera and microphone requests to the user (B-410). Location
/// is always denied: the phone's position isn't the agent's to have.
/// Downloads and workspace captures have nowhere to go here.
@MainActor final class LeoIOSBrowserTabs: NSObject, LeoBrowserTabs, WKUIDelegate {
    static let blank = URL(string: "about:blank")!

    private struct Tab {
        let id: Int
        let page: LeoIOSBrowserPage
        let observations: [NSKeyValueObservation]
    }

    /// The user's own tap or key in any tab.
    var onUserInput: (@MainActor () -> Void)?
    /// After any change to the tabs, the active tab, a tab's URL, title,
    /// loading or history, or its open dialog or permission ask.
    var onChange: (@MainActor () -> Void)?
    /// A page's navigation was refused (see `LeoIOSBrowserPage.onRefusal`).
    var onRefusal: (@MainActor (LeoBrowserError) -> Void)?

    let agentName: String
    let dialogs = LeoBrowserDialogDesk()
    private let configuration: WKWebViewConfiguration
    private let allowsURL: (URL) -> Bool
    private let refusal: (URL) -> LeoBrowserError?
    private let viewHost: LeoIOSBrowserParking
    private lazy var permissions = LeoBrowserPermissionDesk { [weak self] tab, request, denial in
        self?.note(denial, of: request, inTab: tab)
    }
    private var stopObservingDialogs: (@MainActor () -> Void)?
    private var list: [Tab] = []
    private(set) var closedTabs = LeoBrowserClosedTabs()
    private var activeID: Int?
    private var nextID = 1

    init(
        agentName: String, configuration: WKWebViewConfiguration, viewHost: LeoIOSBrowserParking,
        allowsURL: @escaping (URL) -> Bool = LeoBrowserURLPolicy.allows, refusal: @escaping (URL) -> LeoBrowserError?
    ) {
        self.agentName = agentName
        self.configuration = configuration
        self.viewHost = viewHost
        self.allowsURL = allowsURL
        self.refusal = refusal
        super.init()
        stopObservingDialogs = dialogs.observe { [weak self] _ in self?.onChange?() }
    }

    var dataStore: WKWebsiteDataStore { configuration.websiteDataStore }
    var activePage: LeoIOSBrowserPage? { list.first { $0.id == activeID }?.page }
    var activeTabID: Int? { activeID }

    func tabID(of webView: WKWebView) -> Int? {
        list.first { $0.page.webView === webView }?.id
    }

    // MARK: - LeoBrowserTabs

    var tabs: [LeoBrowserTabInfo] {
        list.map {
            LeoBrowserTabInfo(
                id: $0.id, url: $0.page.url, title: $0.page.title, isActive: $0.id == activeID,
                waitingPermission: permissions.waiting(inTab: $0.id)?.request
            )
        }
    }

    var downloads: [LeoBrowserDownload] { [] }

    func page(forTab id: Int?) -> (any LeoBrowserPage)? {
        list.first { $0.id == (id ?? activeID) }?.page
    }

    func openTab(url: URL, userAgent: String?) async throws -> Int {
        try await openTab(url: url, userAgent: userAgent, at: nil)
    }

    func openTab(url: URL, userAgent: String?, at index: Int?) async throws -> Int {
        let tab = add(makePage(configuration), at: index)
        tab.page.setUserAgent(userAgent)
        try await tab.page.load(url)
        return tab.id
    }

    func saveCapture(_ data: Data, kind: LeoBrowserCaptureKind, path: String?, defaultName: String) async throws -> LeoBrowserSavedDownload {
        throw LeoBrowserError(.unsupported, "Leo on iPhone has no workspace to save into.")
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

    func takeClosedTab() -> LeoClosedTab? { closedTabs.popLast() }

    func closeAll() {
        let closing = list
        list = []
        activeID = nil
        closing.forEach(tear(down:))
        onChange?()
    }

    // MARK: - WKUIDelegate

    /// A page opened a window: it becomes the active tab, unless the browser
    /// is full, when the opener's console says why.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let opener = list.first { $0.page.webView === webView }?.page
        guard list.count < LeoBrowserLimits.maximumTabs else {
            let limit = LeoBrowserError.tabLimit(LeoBrowserLimits.maximumTabs)
            opener?.noteConsole(level: "error", text: "tab_limit: \(limit.message); a new window was not opened")
            return nil
        }
        let popup = add(makePage(configuration))
        let override = opener?.webView.customUserAgent
        popup.page.setUserAgent(override.flatMap { $0.isEmpty ? nil : $0 })
        return popup.page.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let id = tabID(of: webView) else { return }
        closeTab(id)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await openDialog(for: webView, kind: .alert, message: message, defaultText: nil, frame: frame)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await openDialog(for: webView, kind: .confirm, message: message, defaultText: nil, frame: frame).accepted
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        await openDialog(for: webView, kind: .prompt, message: prompt, defaultText: defaultText, frame: frame).text
    }

    /// "Leave this page?" — WebKit's private twin; without it every page
    /// leaves unasked. `true` leaves.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(
        _ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        Task { completionHandler(await openDialog(for: webView, kind: .leave, message: message, defaultText: nil, frame: frame).accepted) }
    }

    /// Puts the dialog on the desk for `webView`'s tab; one from a web view
    /// that is no longer a tab is dismissed at once.
    private func openDialog(
        for webView: WKWebView, kind: LeoBrowserDialogKind, message: String, defaultText: String?, frame: WKFrameInfo
    ) async -> LeoBrowserDialogReply {
        let dismissed = LeoBrowserDialogReply(accepted: kind == .alert, text: nil)
        guard let tab = tabID(of: webView) else { return dismissed }
        let site = LeoBrowserSite(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
        return await withCheckedContinuation { continuation in
            dialogs.open(tab: tab, kind: kind, message: message, defaultText: defaultText, site: site) { continuation.resume(returning: $0) }
        }
    }

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        guard let kind = Self.kind(type), let tab = list.first(where: { $0.page.webView === webView }) else { return .deny }
        let site = LeoBrowserSite(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
        let request = LeoBrowserPermissionRequest(kind: kind, site: site)
        let isShown = tab.id == activeID && viewHost.isShown(webView)
        let allowed = await withCheckedContinuation { continuation in
            if permissions.receive(request, inTab: tab.id, isShown: isShown, decide: { continuation.resume(returning: $0) }) { onChange?() }
        }
        return allowed ? .grant : .deny
    }

    /// Location, on iOS 27's public method and its private twin before it:
    /// denied, with a console line saying so.
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        denyLocation(for: webView, origin: origin)
        decisionHandler(.deny)
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func legacyWebView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        denyLocation(for: webView, origin: origin)
        decisionHandler(.deny)
    }

    static let locationDenied = "the agent browser on iPhone never shares this device's location"

    private func denyLocation(for webView: WKWebView, origin: WKSecurityOrigin) {
        let site = LeoBrowserSite(scheme: origin.protocol, host: origin.host, port: origin.port)
        let line = "\(LeoBrowserPermissionText.deniedCode): \(site.origin) was denied access to your location: \(Self.locationDenied)."
        list.first { $0.page.webView === webView }?.page.noteConsole(level: "error", text: line)
    }

    private static func kind(_ type: WKMediaCaptureType) -> LeoBrowserPermissionKind? {
        switch type {
        case .camera: .camera
        case .microphone: .microphone
        case .cameraAndMicrophone: .cameraAndMicrophone
        @unknown default: nil
        }
    }

    // MARK: - Asks and dialogs, for the pane

    var pendingPermission: LeoBrowserPermissionPrompt? {
        guard let activeID, let ask = permissions.waiting(inTab: activeID) else { return nil }
        return LeoBrowserPermissionPrompt(id: ask.id, agent: agentName, request: ask.request)
    }

    func answerPermission(_ prompt: LeoBrowserPermissionPrompt, allow: Bool) {
        guard let activeID, permissions.answer(prompt.id, allow: allow, inTab: activeID) else { return }
        onChange?()
    }

    var pendingDialog: LeoBrowserDialogPrompt? {
        guard let tab = activeID, let dialog = dialogs.dialog(inTab: tab) else { return nil }
        return LeoBrowserDialogPrompt(agent: agentName, dialog: dialog)
    }

    func answerDialog(_ prompt: LeoBrowserDialogPrompt, accept: Bool, text: String?) {
        _ = dialogs.answer(inTab: prompt.dialog.tab, dialog: prompt.id, accept: accept, text: text, by: .user)
    }

    func withdrawActiveDialog() {
        guard let activeID else { return }
        dialogs.withdraw(inTab: activeID)
    }

    /// The pane stopped showing the active tab (it closed, or the app left
    /// the foreground): its ask is denied and withdrawn (D-894). Dialogs
    /// stay pending for whoever answers first (D-913).
    func paneHidden() {
        guard let activeID, permissions.withdraw(inTab: activeID, because: .paneHidden) else { return }
        onChange?()
    }

    private func note(_ denial: LeoBrowserPermissionDenial, of request: LeoBrowserPermissionRequest, inTab tab: Int) {
        let line = LeoBrowserPermissionText.deniedLine(kind: request.kind, origin: request.site.origin, because: denial)
        list.first { $0.id == tab }?.page.noteConsole(level: "error", text: line)
    }

    // MARK: - Helpers

    private func makePage(_ configuration: WKWebViewConfiguration) -> LeoIOSBrowserPage {
        LeoIOSBrowserPage(configuration: configuration, allowsURL: allowsURL, refusal: refusal)
    }

    private func add(_ page: LeoIOSBrowserPage, at index: Int? = nil) -> Tab {
        let id = nextID
        nextID += 1
        page.webView.uiDelegate = self
        page.onUserInput = { [weak self] in self?.onUserInput?() }
        page.onRefusal = { [weak self] in self?.onRefusal?($0) }
        page.onCommit = { [weak self] in
            if self?.permissions.withdraw(inTab: id, because: .navigated) == true { self?.onChange?() }
            self?.dialogs.withdraw(inTab: id)
        }
        page.onContentProcessTerminate = { [weak self] in
            if self?.permissions.withdraw(inTab: id, because: .pageStopped) == true { self?.onChange?() }
            self?.dialogs.withdraw(inTab: id)
        }
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
        viewHost.park(page.webView)
        onChange?()
        return tab
    }

    private func tear(down tab: Tab) {
        tab.observations.forEach { $0.invalidate() }
        tab.page.onUserInput = nil
        tab.page.onRefusal = nil
        tab.page.onCommit = nil
        tab.page.onContentProcessTerminate = nil
        permissions.forget(tab: tab.id)
        // WebKit raises if a dialog's completion handler goes unanswered.
        dialogs.withdraw(inTab: tab.id)
        tab.page.webView.uiDelegate = nil
        tab.page.webView.stopLoading()
        tab.page.webView.removeFromSuperview()
    }
}
