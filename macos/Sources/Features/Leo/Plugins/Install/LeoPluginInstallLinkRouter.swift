import Combine
import Foundation
import LeoKit
import OSLog

/// Receives `leo://plugin/install` links and hands each one to the Plugins
/// pane. A link never installs anything: it only fills in the Install-from-URL
/// sheet. Links are dropped while any install or update sheet is up (so a page
/// can't spam sheets) and held while the plugin system is still starting.
@MainActor final class LeoPluginInstallLinkRouter {
    /// Opens Settings ▸ Plugins; false if Settings stayed where it was.
    private let openPluginsSettings: @MainActor () -> Bool
    private let showError: @MainActor (String) -> Void
    private let logger: Logger
    private var isReady = false
    private var isShowingError = false

    /// The link waiting for the Plugins pane to take it.
    private(set) var pending: LeoPluginInstallLink?
    /// Each Plugins pane model that has its install sheet, an install, or an update up holds a token here.
    /// One pane ending can't reopen the door while another's run is still going.
    private var installUIOwners: Set<UUID> = []
    var isInstallUIOpen: Bool { !installUIOwners.isEmpty }
    /// Fires after a link becomes pending and the router is ready to show it.
    let linkAvailable = PassthroughSubject<Void, Never>()

    init(
        openPluginsSettings: @escaping @MainActor () -> Bool, showError: @escaping @MainActor (String) -> Void, logger: Logger
    ) {
        self.openPluginsSettings = openPluginsSettings
        self.showError = showError
        self.logger = logger
    }

    func receive(_ url: URL) {
        // Before parsing: a malformed link must not get past the guard that stops a page spamming us.
        guard !isInstallUIOpen, pending == nil, !isShowingError else {
            logger.notice("ignored plugin install link: sheet open")
            return
        }
        switch LeoPluginInstallLink.parse(url) {
        case .failure(let error):
            logger.notice("rejected plugin install link: \(error.localizedDescription, privacy: .public)")
            // The alert is modal and runs its own event loop, so more links can arrive while it is up.
            isShowingError = true
            defer { isShowingError = false }
            showError(error.localizedDescription)
        case .success(let link):
            pending = link
            if isReady { present() }
        }
    }

    /// The plugin system is up: show a link that arrived at launch.
    func markReady() {
        guard !isReady else { return }
        isReady = true
        if pending != nil { present() }
    }

    func beginInstallUI(_ owner: UUID) { installUIOwners.insert(owner) }

    func endInstallUI(_ owner: UUID) { installUIOwners.remove(owner) }

    func take() -> LeoPluginInstallLink? {
        defer { pending = nil }
        return pending
    }

    private func present() {
        guard openPluginsSettings() else {
            // The person stayed on their unsaved edits: the link must not sit here refusing every later one.
            pending = nil
            logger.notice("dropped plugin install link: Settings did not navigate")
            return
        }
        linkAvailable.send()
    }
}
