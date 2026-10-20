import AppKit
import Combine
import LeoKit

/// Offers Claude setup once, after the first live local daemon, and backs
/// Agents ▸ Set Up Claude… afterwards. Alert and window wiring only; the
/// decisions are `LeoClaudeOnboarding`'s.
@MainActor final class LeoClaudeOnboardingController {
    private let locator: LeoClaudeLocator
    private let store: LeoClaudeOnboardingStore
    private let openWindow: (String) -> Bool
    private var subscription: AnyCancellable?

    init(locator: LeoClaudeLocator, store: LeoClaudeOnboardingStore, openWindow: @escaping (String) -> Bool) {
        self.locator = locator
        self.store = store
        self.openWindow = openWindow
    }

    /// Watches the sidebar's snapshots for the first live local daemon.
    func start(model: LeoSidebarModel) {
        subscription = model.$snapshot.sink { [weak self] snapshot in
            self?.snapshotLanded(snapshot)
        }
    }

    /// Leo menu: runs setup on request, whether or not claude is present.
    func setUp() {
        _ = openWindow(LeoClaudeOnboarding.installCommand)
    }

    private func snapshotLanded(_ snapshot: LeoSidebarSnapshot) {
        let live = snapshot.connectivity == .connected && snapshot.advertised.host == .local
        guard live, !store.wasOffered else { return }
        let shouldOffer = LeoClaudeOnboarding.shouldOffer(
            claudePath: locator.locate(), alreadyShown: store.wasOffered, hasLiveLocalDaemon: live
        )
        // Remembered either way: a machine that already has claude never asks.
        store.markOffered()
        guard shouldOffer else { return }
        Task { @MainActor in offer() }
    }

    private func offer() {
        let alert = NSAlert()
        alert.messageText = "Set up Claude for your agents?"
        alert.informativeText = "Leo’s agents run on Claude Code, which isn’t installed yet. "
            + "Leo can install it and open the sign-in in a new window. "
            + "You can do this later from Agents ▸ Set Up Claude…"
        alert.addButton(withTitle: "Set Up…")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setUp()
    }
}
