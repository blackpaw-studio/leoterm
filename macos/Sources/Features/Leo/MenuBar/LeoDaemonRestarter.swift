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
/// answer maps to an outcome. A CLI daemon's restart runs the resolved leo as
/// before. Neither ever shows a raw launchd or stderr message.
struct LeoDaemonRestarter: Sendable {
    static let arguments = ["service", "restart", "--graceful"]
    /// The graceful drain waits up to 10 minutes before leo forces it.
    static let timeout: TimeInterval = 11 * 60
    static let doctorAdvice = "Run “leo doctor” in Terminal, or see ~/.leo/state/service.log."
    private static let didNotRestart = "Leo’s daemon didn’t restart. \(doctorAdvice)"

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let cli: LeoCLI
    let bundledExecutable: String

    /// Never throws and never carries leo's stderr or launchd's error text.
    func restart(isManaged: Bool) async -> LeoDaemonRestartOutcome {
        isManaged ? await restartManaged() : await restartCLI()
    }

    private func restartCLI() async -> LeoDaemonRestartOutcome {
        do {
            let executable = try cli.resolveExecutable()
            let result = try await cli.runner.run(executable: executable, arguments: Self.arguments, timeout: Self.timeout)
            guard result.status == 0 else {
                let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Self.logger.error("leo service restart exited \(result.status): \(stderr, privacy: .public)")
                return .failed(Self.didNotRestart)
            }
            return .restarted
        } catch {
            Self.logger.error("leo service restart didn’t run: \(String(describing: error), privacy: .public)")
            return .failed(Self.didNotRestart)
        }
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
            return .failed(Self.didNotRestart)
        case .malformed(let detail):
            Self.logger.error("leo service restart: \(detail, privacy: .public)")
            return .failed(Self.didNotRestart)
        }
    }
}
