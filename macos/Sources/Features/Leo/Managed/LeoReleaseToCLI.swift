import Foundation
import OSLog

/// B4: hands the daemon back to the CLI install. leo goes first (drain,
/// bootout of the app's label, CLI daemon restored); only on `ok:true` does
/// the app drop its marker and unregister. A crash between the two is
/// recovered at the next launch (B1's orphan registration row).
struct LeoReleaseToCLI: Sendable {
    enum Outcome: Equatable, Sendable {
        case declined
        case released(warnings: [String])
        /// `reRegistered`: leo had stopped the app's daemon and rolled back,
        /// so the app registered its agent again.
        case failed(message: String, reRegistered: Bool)
    }

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let handover: LeoHandover
    let agent: any LeoLaunchAgentService
    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem

    func run(confirm: () async -> Bool) async -> Outcome {
        guard await confirm() else { return .declined }
        // The restored CLI plist runs `~/.local/bin/leo`: it must be the CLI's
        // own binary again before leo bootstraps it, not the app's helper.
        let restoredCommand = restoreCommandBackup()
        let result: LeoHandoverResult?
        switch await handover.toCLI() {
        case .succeeded(let value):
            return await finishRelease(warnings: value.warnings)
        case .failed(let value):
            result = value
        case .malformed(let message):
            Self.logger.error("release to CLI: \(message, privacy: .public)")
            result = nil
        }
        if restoredCommand { undoCommandRestore() }
        let message = result?.message ?? result?.error ?? "leo didn’t hand the daemon back to the CLI"
        guard result?.managedStopped == true else { return .failed(message: message, reRegistered: false) }
        do {
            try await agent.register()
        } catch {
            return .failed(message: "\(message). Leo couldn’t restart its own daemon: \(error)", reRegistered: false)
        }
        return .failed(message: message, reRegistered: true)
    }

    private func finishRelease(warnings: [String]) async -> Outcome {
        var warnings = warnings
        do {
            // leo normally removes it; `remove()` never reads the bundle id.
            try LeoMarkerStore(paths: paths, fileSystem: fileSystem, bundleID: "").remove()
        } catch {
            warnings.append("Couldn’t remove \(paths.markerURL.path): \(error)")
        }
        do {
            try await agent.unregister()
        } catch {
            warnings.append("Leo’s agent is still registered; it is removed at the next launch (\(error))")
        }
        return .released(warnings: warnings)
    }

    private var isOurCommandLink: Bool {
        fileSystem.kind(at: paths.localBinLeo) == .symlink(target: paths.selfLinkURL.path)
    }

    /// Puts `leo.pre-leoapp` back over our `~/.local/bin/leo` link (A14).
    private func restoreCommandBackup() -> Bool {
        guard isOurCommandLink, fileSystem.kind(at: paths.localBinLeoBackup) != .absent else { return false }
        do {
            try fileSystem.move(from: paths.localBinLeoBackup, to: paths.localBinLeo)
            return true
        } catch {
            Self.logger.error("release to CLI: restoring the leo command failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Nothing was released: the command goes back to being our link.
    private func undoCommandRestore() {
        do {
            try fileSystem.moveWithoutReplacing(from: paths.localBinLeo, to: paths.localBinLeoBackup)
            try fileSystem.symlink(at: paths.localBinLeo, to: paths.selfLinkURL.path)
        } catch {
            Self.logger.error("release to CLI: re-linking the leo command failed: \(String(describing: error), privacy: .public)")
        }
    }
}
