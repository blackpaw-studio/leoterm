import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    /// The error `updater(_:mayPerform:)` throws to make Sparkle skip a
    /// background check this build can't act on.
    enum CheckRefusal {
        static let domain = "studio.blackpaw.leo.update"
        static let code = 1
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        return UpdateFeed.urlString(for: appDelegate.ghostty.config.autoUpdateChannel)
    }

    /// Debug builds refuse a background check while automatic downloads are
    /// on: Sparkle would download and install on quit without asking us, so
    /// no reply gate could stop it (see `UpdatePolicy.mayCheck`).
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !UpdatePolicy.mayCheck(
            updateCheck,
            automaticallyDownloads: updater.automaticallyDownloadsUpdates,
            installsAllowed: installsAllowed
        ) else { return }
        AppDelegate.logger.info("skipping a background update check: this build can't install updates")
        throw NSError(domain: CheckRefusal.domain, code: CheckRefusal.code, userInfo: [
            NSLocalizedDescriptionKey: "This build can't install updates automatically.",
        ])
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
