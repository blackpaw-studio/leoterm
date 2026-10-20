import Foundation

enum LeoMoveDestinationState: Equatable, Sendable {
    case absent
    case present(isRunning: Bool)
}

enum LeoMoveOutcome: Equatable, Sendable {
    /// The copy in /Applications was opened and this process is quitting.
    case relaunched
    case manualInstructionsShown
    case declinedReplace
    case refusedRunning
    case failed(String)
}

/// Everything the mover touches outside itself, so tests assert the exact
/// sequence. Local to the UI work; to be consolidated with `LeoFileSystem`
/// (A6) once that lands.
@MainActor protocol LeoAppMoverEnvironment: AnyObject {
    func destinationState(at url: URL) -> LeoMoveDestinationState
    func isApplicationsWritable() -> Bool
    /// The file work is `async` because it can take a long time (a DMG or a
    /// network volume) and must not hold the main thread.
    ///
    /// Replaces `target` when it exists (a stale staging copy).
    func copyBundle(from source: URL, to target: URL) async throws
    func moveBundle(from source: URL, to target: URL) async throws
    func trash(_ url: URL) async throws
    /// The instance claim: a copy launched next waits for this process to
    /// exit instead of yielding to it (B-092).
    func markInstanceExiting()
    func clearInstanceExiting()
    func openNewInstance(at url: URL) async throws
    func terminate()
    func askReplace(existing: URL) -> Bool
    func explainRunningCopy(at url: URL)
    func showManualInstructions(for bundleURL: URL)
    func report(error message: String)
}

/// Copies Leo into /Applications and hands over to that copy (D7).
///
/// The copy is staged beside its destination and renamed into place, so a
/// failed copy never costs the user an installed Leo; the replaced copy goes
/// to the Trash, not away. Both copies share one bundle ID, hence one
/// instance lock: the claim is marked exiting before the launch so the new
/// copy waits for this one rather than yielding to it, and unmarked if the
/// launch fails so a later launch doesn't wait on a process that stays.
@MainActor struct LeoAppMover {
    let environment: any LeoAppMoverEnvironment

    private static let stagingPrefix = "."
    private static let stagingSuffix = ".moving"
    private static let backupSuffix = ".replaced"

    func move(bundleURL: URL, reason: LeoMoveReason) async -> LeoMoveOutcome {
        let applications = URL(fileURLWithPath: LeoAppLocation.applicationsPath)
        let destination = applications.appendingPathComponent(bundleURL.lastPathComponent)
        let staging = applications.appendingPathComponent(
            Self.stagingPrefix + bundleURL.lastPathComponent + Self.stagingSuffix
        )

        guard environment.isApplicationsWritable() else {
            environment.showManualInstructions(for: bundleURL)
            return .manualInstructionsShown
        }
        let replacesExisting: Bool
        switch environment.destinationState(at: destination) {
        case .absent:
            replacesExisting = false
        case .present(isRunning: true):
            environment.explainRunningCopy(at: destination)
            return .refusedRunning
        case .present(isRunning: false):
            guard environment.askReplace(existing: destination) else { return .declinedReplace }
            replacesExisting = true
        }

        let backup = applications.appendingPathComponent(
            Self.stagingPrefix + bundleURL.lastPathComponent + Self.backupSuffix
        )
        do {
            try await environment.copyBundle(from: bundleURL, to: staging)
        } catch {
            return fail(error)
        }
        if let failure = await install(staging: staging, at: destination, keepingExistingAt: replacesExisting ? backup : nil) {
            return failure
        }

        environment.markInstanceExiting()
        do {
            try await environment.openNewInstance(at: destination)
        } catch {
            environment.clearInstanceExiting()
            return fail(error)
        }

        // A translocated or read-only original can't be trashed, and we
        // don't know where a translocated one came from.
        if reason == .elsewhere { try? await environment.trash(bundleURL) }
        environment.terminate()
        return .relaunched
    }

    /// Puts `staging` at `destination`. An installed copy is moved aside to
    /// `backup` first and only trashed once the new one is in place; if the
    /// install fails it's moved back, so Applications never ends up without
    /// a Leo.
    private func install(staging: URL, at destination: URL, keepingExistingAt backup: URL?) async -> LeoMoveOutcome? {
        do {
            if let backup { try await environment.moveBundle(from: destination, to: backup) }
        } catch {
            return fail(error)
        }
        do {
            try await environment.moveBundle(from: staging, to: destination)
        } catch {
            if let backup { try? await environment.moveBundle(from: backup, to: destination) }
            return fail(error)
        }
        if let backup { try? await environment.trash(backup) }
        return nil
    }

    private func fail(_ error: Error) -> LeoMoveOutcome {
        let message = error.localizedDescription
        environment.report(error: message)
        return .failed(message)
    }
}
