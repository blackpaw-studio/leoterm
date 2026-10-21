import AppKit
import Combine
import LeoKit

/// Offers Claude setup (see `LeoClaudeOnboardingModel`) and backs Agents ▸
/// Set Up Claude… afterwards. Alert and window wiring only; the decisions
/// are the model's. The offer never blocks the main actor: a sheet on the
/// front window, else a panel (see `LeoOfferAlertPresenter`).
@MainActor final class LeoClaudeOnboardingController: LeoClaudeOfferPresenting {
    private let openWindow: (String) -> Bool
    private var subscription: AnyCancellable?
    private lazy var model = LeoClaudeOnboardingModel(health: health, locate: { await self.locator.locate() }, locateFixed: { self.locator.locateFixed() }, store: store, presenter: self)
    private let locator: LeoClaudeLocator
    private let health: () async -> LeoClaudeHealth
    private let store: LeoClaudeOnboardingStore
    private let offerPresenter: LeoOfferAlertPresenter

    init(
        locator: LeoClaudeLocator, health: @escaping () async -> LeoClaudeHealth,
        store: LeoClaudeOnboardingStore, openWindow: @escaping (String) -> Bool,
        hostWindow: @escaping () -> NSWindow? = LeoClaudeOnboardingController.frontWindow
    ) {
        self.locator = locator
        self.health = health
        self.store = store
        self.openWindow = openWindow
        offerPresenter = LeoOfferAlertPresenter(hostWindow: hostWindow)
    }

    /// The window the offer sheets onto: a visible main or key window that
    /// is not already showing a sheet.
    static func frontWindow() -> NSWindow? {
        [NSApp.mainWindow, NSApp.keyWindow].lazy.compactMap { $0 }
            .first { $0.isVisible && $0.attachedSheet == nil && !$0.isSheet && !($0 is NSPanel) }
    }

    /// Watches the sidebar's snapshots for a live local daemon.
    func start(model sidebar: LeoSidebarModel) {
        subscription = sidebar.$snapshot.sink { [weak self] snapshot in
            let live = snapshot.connectivity == .connected && snapshot.advertised.host == .local
            Task { @MainActor in await self?.model.snapshotLanded(hasLiveLocalDaemon: live) }
        }
    }

    /// Leo menu: runs setup on request, whether or not claude is present.
    func setUp() {
        _ = openWindow(LeoClaudeOnboarding.installCommand)
    }

    /// An agent spawn failed with `claude_not_found`.
    func claudeNotFound() {
        Task { @MainActor in await model.claudeNotFound() }
    }

    /// Back from installing in a terminal, say.
    func applicationDidBecomeActive() {
        Task { @MainActor in await model.recheckOpenOffer() }
    }

    // MARK: LeoClaudeOfferPresenting

    func presentOffer() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Set up Claude for your agents?"
        alert.informativeText = "Leo’s agents run on Claude Code, which isn’t installed yet. "
            + "Leo can install it and open the sign-in in a new window. "
            + "You can do this later from Agents ▸ Set Up Claude…"
        alert.addButton(withTitle: "Set Up…")
        alert.addButton(withTitle: "Not Now")
        return await offerPresenter.present(alert)
    }

    func withdrawOffer() {
        offerPresenter.withdraw()
    }

    func runSetUp() { setUp() }
}
