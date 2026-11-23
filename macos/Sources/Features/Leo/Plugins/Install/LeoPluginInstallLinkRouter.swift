import Combine
import Foundation
import LeoKit
import OSLog

/// Receives `leo://plugin/install` links and hands each one to the Plugins
/// pane. A link never installs anything: it only fills in the Install-from-URL
/// sheet. Links are dropped while any install or update sheet is up (so a page
/// can't spam sheets) and held while the plugin system is still starting.
@MainActor final class LeoPluginInstallLinkRouter {
    private let openPluginsSettings: @MainActor () -> Void
    private let showError: @MainActor (String) -> Void
    private let logger: Logger
    private var isReady = false

    /// The link waiting for the Plugins pane to take it.
    private(set) var pending: LeoPluginInstallLink?
    /// The Plugins pane sets this while its install sheet, an install, or an update is up.
    var isInstallUIOpen = false
    /// Fires after a link becomes pending and the router is ready to show it.
    let linkAvailable = PassthroughSubject<Void, Never>()

    init(
        openPluginsSettings: @escaping @MainActor () -> Void, showError: @escaping @MainActor (String) -> Void, logger: Logger
    ) {
        self.openPluginsSettings = openPluginsSettings
        self.showError = showError
        self.logger = logger
    }

    func receive(_ url: URL) {
        switch LeoPluginInstallLink.parse(url) {
        case .failure(let error):
            logger.notice("rejected plugin install link: \(error.localizedDescription, privacy: .public)")
            showError(error.localizedDescription)
        case .success(let link):
            guard !isInstallUIOpen, pending == nil else {
                logger.notice("ignored plugin install link: sheet open")
                return
            }
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

    func take() -> LeoPluginInstallLink? {
        defer { pending = nil }
        return pending
    }

    private func present() {
        openPluginsSettings()
        linkAvailable.send()
    }
}
