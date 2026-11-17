import LeoKit
import WebKit


/// A page's JavaScript dialogs (B-412): WebKit's alert, confirm and prompt
/// panels, plus its private beforeunload one, go to the browser's dialog
/// desk, where the user (in the pane) or the agent (`browser_dialog`)
/// answers. Never WebKit's own sheet: an agent's click must not freeze the
/// window the terminals share, and a dialog on a hidden tab waits.
@available(macOS 14, *)
extension LeoAgentBrowserTabs {
    @objc(webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        openDialog(for: webView, kind: .alert, message: message, defaultText: nil, frame: frame) { _ in completionHandler() }
    }

    @objc(webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        openDialog(for: webView, kind: .confirm, message: message, defaultText: nil, frame: frame) { completionHandler($0.accepted) }
    }

    @objc(webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:)
    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        openDialog(for: webView, kind: .prompt, message: prompt, defaultText: defaultText, frame: frame) { completionHandler($0.text) }
    }

    /// "Leave this page?" WebKit has no public delegate method for it: a
    /// delegate without this private one lets every page go unasked. It
    /// asks only when the page had a user gesture and its `beforeunload`
    /// handler wants to stay. `true` leaves.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(
        _ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        openDialog(for: webView, kind: .leave, message: message, defaultText: nil, frame: frame) { completionHandler($0.accepted) }
    }

    /// Puts the dialog on the desk for `webView`'s tab. One from a web view
    /// that is no longer a tab (closing) is dismissed at once. `reply` runs
    /// exactly once either way.
    private func openDialog(
        for webView: WKWebView, kind: LeoBrowserDialogKind, message: String, defaultText: String?, frame: WKFrameInfo,
        reply: @escaping @MainActor (LeoBrowserDialogReply) -> Void
    ) {
        guard let tab = tabID(of: webView) else { return reply(LeoBrowserDialogReply(accepted: kind == .alert, text: nil)) }
        dialogs.open(tab: tab, kind: kind, message: message, defaultText: defaultText, site: LeoBrowserSite(frame.securityOrigin), resolve: reply)
    }

    /// The active tab's open dialog, in remote terms.
    var pendingDialog: LeoBrowserDialogPrompt? {
        guard let tab = activeTabID, let dialog = dialogs.dialog(inTab: tab) else { return nil }
        let shown = LeoBrowserDialog(
            id: dialog.id, tab: dialog.tab, kind: dialog.kind, message: dialog.message, defaultText: dialog.defaultText, site: remote(dialog.site)
        )
        return LeoBrowserDialogPrompt(agent: agentName, dialog: shown)
    }

    /// The user's answer in the bar; nothing when `prompt` was already
    /// answered. Not user input: it doesn't take control.
    func answerDialog(_ prompt: LeoBrowserDialogPrompt, accept: Bool, text: String?) {
        _ = dialogs.answer(inTab: prompt.dialog.tab, dialog: prompt.id, accept: accept, text: text, by: .user)
    }

    /// The user is about to load something else in the active tab: its
    /// dialog is dismissed first, or the paused page would never go.
    func withdrawActiveDialog() {
        guard let tab = activeTabID else { return }
        dialogs.withdraw(inTab: tab)
    }
}
