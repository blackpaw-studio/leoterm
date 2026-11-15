import Foundation

/// What happens once Leo's quit is certain: the copy in /Applications is
/// launched and the original is trashed.
struct LeoMoveHandoff: Equatable, Sendable {
    let destination: URL
    /// The original bundle to trash; nil when it can't be (translocated, read-only).
    let original: URL?
}

@MainActor protocol LeoMoveHandoffEnvironment: AnyObject {
    func markInstanceExiting()
    func clearInstanceExiting()
    /// Synchronous: it runs while the app terminates.
    func launchNewInstance(at url: URL) throws
    func trashOriginal(_ url: URL) throws
    func reportHandoffFailure(_ message: String)
}

/// Holds the handoff until Leo's quit is certain.
///
/// Quitting can be cancelled (a running-process or unsaved-changes prompt)
/// with no callback saying so. The mover's own `terminate` is the first
/// quit attempt `AppDelegate` reports; any attempt after that means the
/// first one didn't go through, so the handoff is dropped rather than left
/// to fire on a later, unrelated quit. A quit that was only deferred ends in
/// `willTerminate`, which runs the handoff.
@MainActor final class LeoMoveHandoffCoordinator {
    private let environment: any LeoMoveHandoffEnvironment
    private var pending: LeoMoveHandoff?
    private var hasSeenAttempt = false

    init(environment: any LeoMoveHandoffEnvironment) {
        self.environment = environment
    }

    func arm(_ handoff: LeoMoveHandoff) {
        pending = handoff
        hasSeenAttempt = false
    }

    /// Every quit attempt, from `applicationShouldTerminate`.
    func terminationAttemptBegan() {
        guard pending != nil else { return }
        guard !hasSeenAttempt else {
            pending = nil
            return
        }
        hasSeenAttempt = true
    }

    /// Termination is certain: launch the copy (it waits on the instance lock
    /// until this process is gone), then trash the original.
    func willTerminate() {
        guard let handoff = pending else { return }
        pending = nil
        environment.markInstanceExiting()
        do {
            try environment.launchNewInstance(at: handoff.destination)
        } catch {
            environment.clearInstanceExiting()
            environment.reportHandoffFailure(error.localizedDescription)
            return
        }
        if let original = handoff.original { try? environment.trashOriginal(original) }
    }
}
