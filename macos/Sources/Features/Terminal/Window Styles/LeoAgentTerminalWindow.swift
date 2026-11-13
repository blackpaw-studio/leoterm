import AppKit
import Combine

/// The window every Leo agent window uses, whatever `macos-titlebar-style`
/// says: a titled window with a unified toolbar (title and subtitle on the
/// leading edge, the activity capsule centred, a "⋯" menu trailing) over a
/// full-size content view, so the glass sidebar runs under the traffic
/// lights. Settings, browser and editor panes keep their own chrome.
///
/// `window-decoration = false` still means no titlebar and no toolbar: the
/// controller picks the plain `Terminal` nib then.
final class LeoAgentTerminalWindow: TerminalWindow {
    /// The toolbar's delegate; the window owns it (an `NSToolbar` holds its
    /// delegate weakly).
    let leoToolbar = LeoAgentToolbar()
    /// What keeps the window's chrome in step with the app's state (the
    /// subtitle), released with the window.
    var chromeSubscriptions: Set<AnyCancellable> = []
    private var contentLayoutObservation: NSKeyValueObservation?
    private var fullScreenObservers: [NSObjectProtocol] = []

    /// B-349: the pill is a toolbar item here (`LeoAgentToolbar`); a titlebar
    /// accessory hangs under the unified toolbar, off its row.
    override var supportsUpdateAccessory: Bool { false }
    override var showsUpdateInToolbar: Bool { true }
    /// B-358: so is the reset-zoom button, for the same reason.
    override var showsResetZoomInToolbar: Bool { true }

    override func awakeFromNib() {
        super.awakeFromNib()
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = false
        // The toolbar's title item stands in for the window's own title.
        titleVisibility = .hidden
        toolbarStyle = .unified
    }

    deinit {
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Puts the toolbar on the window and keeps `inset` equal to its real
    /// height: through the toolbar's own changes (a subtitle appearing) and
    /// full screen, which releases it at rest.
    @MainActor
    func installToolbar(inset: LeoToolbarInset) {
        leoToolbar.install(on: self)
        inset.update(from: self)
        contentLayoutObservation = observe(\.contentLayoutRect, options: [.new]) { [weak inset] window, _ in
            MainActor.assumeIsolated { inset?.update(from: window) }
        }
        let center = NotificationCenter.default
        fullScreenObservers = [
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification,
        ].map { name in
            center.addObserver(forName: name, object: self, queue: .main) { [weak self, weak inset] _ in
                MainActor.assumeIsolated {
                    guard let self, let inset else { return }
                    inset.update(from: self)
                }
            }
        }
    }
}
