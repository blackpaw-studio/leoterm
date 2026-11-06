import Foundation

/// B-339: turns on the daemon's loopback web API through the bundled
/// `leo web enable`, so leo validates and writes the section itself and
/// restarts through the same graceful routing as `service restart`.
struct LeoManagedWebAPI: Sendable {
    enum Outcome: Equatable, Sendable {
        /// Saved. `restarted` is false when no daemon answered to restart.
        case enabled(restarted: Bool)
        /// Agents stayed busy past the drain: saved, listening after the next restart.
        case drainTimedOut
        case notRegistered(message: String)
        case failed(message: String)
    }

    /// `leo web enable --json`'s success.
    struct Enabled: Decodable, Equatable, Sendable {
        let changed: Bool?
        let restarted: Bool?
    }

    static let loopback = "127.0.0.1"

    let runner: any LeoProcessRunning
    let bundledLeo: String
    let configPath: String

    func enable() async -> Outcome {
        let arguments = ["web", "enable", "--bind", Self.loopback, "--config", configPath, "--json"]
        let result: LeoProcessResult
        do {
            result = try await runner.run(executable: bundledLeo, arguments: arguments, timeout: LeoHandover.timeout)
        } catch {
            return .failed(message: "leo web enable didn’t run: \(error)")
        }
        switch LeoJSONAnswer<Enabled>(result) {
        case .succeeded(let answer): return .enabled(restarted: answer.restarted ?? false)
        case .failed(let failure): return Self.outcome(for: failure)
        case .malformed(let message): return .failed(message: message)
        }
    }

    private static func outcome(for failure: LeoJSONFailure) -> Outcome {
        switch failure.error {
        case LeoPostUpdateRestart.codeNotRegistered: .notRegistered(message: failure.message ?? "Leo’s LaunchAgent isn’t loaded")
        case LeoPostUpdateRestart.codeDrainTimeout: .drainTimedOut
        default: .failed(message: failure.summary)
        }
    }
}
