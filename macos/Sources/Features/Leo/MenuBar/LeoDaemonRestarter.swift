import Foundation
import LeoKit
import OSLog

/// What Restart Daemon did, for the menu bar.
enum LeoDaemonRestartOutcome: Equatable, Sendable {
    case restarted
    /// leo says the app's job isn't loaded: a daemon outside Leo.app may be
    /// answering (B10). The caller decides; nothing was restarted.
    case notRegistered
    /// Friendly text. Never leo's stderr.
    case failed(String)
}

/// Restarts the daemon from the menu bar (A11). Always `--graceful`: that
/// drains without prompting, which bare `restart` may do. A managed daemon
/// is restarted by the bundled binary by explicit path (D6) so the restart
/// targets the app's label; leo routes it from the marker, and its `--json`
/// answer maps to an outcome (a raw launchd error is never shown).
struct LeoDaemonRestarter: Sendable {
    static let arguments = ["service", "restart", "--graceful"]
    /// The graceful drain waits up to 10 minutes before leo forces it.
    static let timeout: TimeInterval = 11 * 60
    static let doctorAdvice = "Run “leo doctor” in Terminal, or see ~/.leo/state/service.log."

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let cli: LeoCLI
    let bundledExecutable: String

    /// A CLI daemon's failure throws leo's stderr; a managed daemon's never does.
    func restart(isManaged: Bool) async throws -> LeoDaemonRestartOutcome {
        isManaged ? await restartManaged() : try await restartCLI()
    }

    private func restartCLI() async throws -> LeoDaemonRestartOutcome {
        let executable = try cli.resolveExecutable()
        let result = try await cli.runner.run(executable: executable, arguments: Self.arguments, timeout: Self.timeout)
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LeoDaemonError.transport(message.flatMap { $0.isEmpty ? nil : $0 } ?? "leo exited \(result.status)")
        }
        return .restarted
    }

    private func restartManaged() async -> LeoDaemonRestartOutcome {
        let result: LeoProcessResult
        do {
            result = try await cli.runner.run(
                executable: bundledExecutable, arguments: Self.arguments + ["--json"], timeout: Self.timeout
            )
        } catch {
            Self.logger.error("leo service restart didn’t run: \(String(describing: error), privacy: .public)")
            return .failed("Leo couldn’t run its daemon’s restart. \(Self.doctorAdvice)")
        }
        switch LeoJSONAnswer<LeoPostUpdateRestart.Restarted>(result) {
        case .succeeded:
            return .restarted
        case .failed(let failure) where failure.error == LeoPostUpdateRestart.codeNotRegistered:
            return .notRegistered
        case .failed(let failure) where failure.error == LeoPostUpdateRestart.codeDrainTimeout:
            return .failed("Some agents were still busy, so Leo didn’t restart its daemon. Try again when they’re done.")
        case .failed(let failure):
            Self.logger.error("leo service restart: \(failure.error, privacy: .public) \(failure.summary, privacy: .public)")
            return .failed("Leo’s daemon didn’t restart. \(Self.doctorAdvice)")
        case .malformed(let detail):
            Self.logger.error("leo service restart: \(detail, privacy: .public)")
            return .failed("Leo’s daemon didn’t restart. \(Self.doctorAdvice)")
        }
    }
}
