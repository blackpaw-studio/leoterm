import AppKit

/// Shows an `NSAlert` without blocking the main actor: a sheet on the host
/// window, or a free-standing panel when there is none. The offer is
/// withdrawn by ending exactly the alert this presenter opened.
@MainActor final class LeoOfferAlertPresenter: NSObject {
    private struct Offer {
        let token: Int
        let alert: NSAlert
        let host: NSWindow?
        let continuation: CheckedContinuation<Bool, Never>
        let closeObserver: (any NSObjectProtocol)?
    }

    private let hostWindow: () -> NSWindow?
    private var current: Offer?
    private var offerCount = 0

    init(hostWindow: @escaping () -> NSWindow?) {
        self.hostWindow = hostWindow
    }

    var isOpen: Bool { current != nil }

    /// True when the first button was chosen; false for any other button, a
    /// withdrawal, or an offer already open.
    func present(_ alert: NSAlert) async -> Bool {
        guard current == nil else { return false }
        offerCount += 1
        let token = offerCount
        return await withCheckedContinuation { continuation in
            let host = hostWindow()
            current = Offer(
                token: token, alert: alert, host: host, continuation: continuation,
                closeObserver: host == nil ? observeClose(of: alert, token: token) : nil)
            if let host {
                alert.beginSheetModal(for: host) { [weak self] response in
                    self?.finish(token, accepted: response == .alertFirstButtonReturn)
                }
            } else {
                showPanel(alert)
            }
        }
    }

    /// Ends the open offer, and only it, as declined.
    func withdraw() {
        guard let offer = current else { return }
        finish(offer.token, accepted: false)
        if let host = offer.host {
            host.endSheet(offer.alert.window, returnCode: .abort)
        } else {
            offer.alert.window.close()
        }
    }

    @objc private func panelButtonPressed(_ sender: NSButton) {
        guard let offer = current, offer.host == nil, offer.alert.buttons.contains(sender) else { return }
        finish(offer.token, accepted: sender === offer.alert.buttons.first)
        offer.alert.window.close()
    }

    private func showPanel(_ alert: NSAlert) {
        for button in alert.buttons {
            button.target = self
            button.action = #selector(panelButtonPressed(_:))
        }
        // NSAlert only lays itself out when it runs; do it before the frame is used.
        alert.layout()
        let window = alert.window
        window.level = .floating
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing the panel any other way (⌘W, say) declines.
    private func observeClose(of alert: NSAlert, token: Int) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: alert.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(token, accepted: false) }
        }
    }

    /// Resolves the offer once; a stale token (a closed alert's late callback) is ignored.
    private func finish(_ token: Int, accepted: Bool) {
        guard let offer = current, offer.token == token else { return }
        current = nil
        if let observer = offer.closeObserver { NotificationCenter.default.removeObserver(observer) }
        offer.continuation.resume(returning: accepted)
    }
}
