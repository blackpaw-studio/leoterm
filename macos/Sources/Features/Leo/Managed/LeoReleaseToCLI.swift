import Foundation
import OSLog

/// B4: hands the daemon back to the CLI install. leo goes first (drain,
/// bootout of the app's label, marker moved aside, CLI daemon restored,
/// marker deleted); only on `ok` with the app's job stopped does the app
/// unregister. A crash between the two is recovered at the next launch
/// (B1's orphan registration row).
struct LeoReleaseToCLI: Sendable {
    enum Outcome: Equatable, Sendable {
        case declined
        case released(warnings: [String])
        /// `reRegistered`: leo had stopped the app's daemon, so the app
        /// restarted its job and hello answered.
        case failed(message: String, reRegistered: Bool)
    }

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let handover: LeoHandover
    let agent: any LeoLaunchAgentService
    let hello: LeoHelloWait
    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem

    func run(confirm: @Sendable () async -> Bool) async -> Outcome {
        guard await confirm() else { return .declined }
        // The restored CLI plist runs `~/.local/bin/leo`: it must be the CLI's
        // own binary again before leo bootstraps it, not the app's helper.
        let restoredCommand: Bool
        do {
            restoredCommand = try restoreCommandBackup()
        } catch {
            Self.logger.error("release to CLI: restoring the leo command failed: \(String(describing: error), privacy: .public)")
            let message = "Leo couldn’t put your own leo back at ~/.local/bin/leo from leo.pre-leoapp, so nothing was handed back: \(error)"
            return .failed(message: message, reRegistered: false)
        }
        let result: LeoJSONFailure?
        switch await handover.toCLI() {
        case .succeeded(let value):
            return await finishRelease(value)
        case .failed(let value):
            result = value
        case .malformed(let message):
            Self.logger.error("release to CLI: \(message, privacy: .public)")
            result = nil
        }
        if restoredCommand { undoCommandRestore() }
        let message = result?.summary ?? "leo didn’t hand the daemon back to the CLI"
        guard result?.managedStopped == true else { return .failed(message: message, reRegistered: false) }
        do {
            _ = try await agent.restartStoppedJob(hello: hello)
        } catch {
            return .failed(message: "\(message). Leo couldn’t restart its own daemon: \(error)", reRegistered: false)
        }
        return .failed(message: message, reRegistered: true)
    }

    /// leo has already deleted the marker; it must not be touched here.
    private func finishRelease(_ result: LeoHandoverResult) async -> Outcome {
        guard result.managedStopped else {
            return .released(warnings: result.warnings + ["leo didn’t report stopping Leo’s daemon, so its login item stays registered"])
        }
        do {
            try await agent.unregister()
        } catch {
            return .released(warnings: result.warnings + ["Leo’s agent is still registered; it is removed at the next launch (\(error))"])
        }
        return .released(warnings: result.warnings)
    }

    private var isOurCommandLink: Bool {
        fileSystem.kind(at: paths.localBinLeo) == .symlink(target: paths.selfLinkURL.path)
    }

    /// Puts `leo.pre-leoapp` back over our `~/.local/bin/leo` link (A14);
    /// false when there was nothing to restore.
    private func restoreCommandBackup() throws -> Bool {
        guard isOurCommandLink, fileSystem.kind(at: paths.localBinLeoBackup) != .absent else { return false }
        try fileSystem.move(from: paths.localBinLeoBackup, to: paths.localBinLeo)
        return true
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
