import Foundation
import OSLog

/// leo v0.56.1's recovery for a `handover --to-app` whose marker never
/// landed: plain `--to-cli` can't find the app's job without one, so it
/// names the label. leo refuses while the app's job is loaded, so a
/// registered job is unregistered first. Runs once; never retried here.
struct LeoMarkerlessRestore: Sendable {
    enum Outcome: Equatable, Sendable {
        case restored
        /// What leo (or the run) said; the CLI daemon may be down.
        case failed(String)
    }

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let handover: LeoHandover
    let agent: any LeoLaunchAgentService
    let label: String

    func run(unregisterFirst: Bool) async -> Outcome {
        if unregisterFirst {
            do {
                try await agent.unregister()
            } catch {
                // leo checks for a loaded job itself (managed_job_loaded).
                Self.logger.error("unregister before the markerless restore failed: \(String(describing: error), privacy: .public)")
            }
        }
        switch await handover.toCLI(label: label) {
        case .succeeded(let result) where result.restoredWithoutMarker: return .restored
        case .succeeded: return .failed("leo didn’t say it restored the CLI daemon")
        case .failed(let refused): return .failed(refused.summary)
        case .malformed(let message): return .failed(message)
        }
    }
}
