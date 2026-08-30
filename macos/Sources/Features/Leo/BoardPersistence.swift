import Foundation

/// Whether a terminal controller is allowed to write the shared board file.
///
/// Board persistence is a single-owner lease: exactly one controller holds it
/// (see `AppDelegate.restoreLeoBoardIfNeeded`), and writing is armed only once
/// a restore has actually completed. A restore that fails — a remote host whose
/// forward is down, for example — leaves the owner disarmed so it can never
/// overwrite the persisted board with an empty one.
///
/// The lease is also released on window teardown (`relinquish()`): closing a
/// window empties its surface tree, and an armed controller would persist that
/// emptiness as the user's board.
enum BoardPersistenceState: Equatable, Sendable {
    /// Does not hold the lease: never writes.
    case idle
    /// Holds the lease but has not restored yet: writes are suppressed.
    case owned
    /// Restore in flight: writes are suppressed until it completes.
    case restoring
    /// Restore completed: writes are allowed.
    case armed
    /// Restore failed: writes stay suppressed to protect saved data.
    case failed

    /// True only when this controller may overwrite the persisted board.
    var canSave: Bool { self == .armed }

    /// True when a previous restore failed and is worth retrying (e.g. when the
    /// window becomes key again and the host may have recovered).
    var needsRestoreRetry: Bool { self == .failed }

    /// Claim the lease. Ignored when this controller already holds it, so an
    /// explicit re-restore does not reset progress.
    mutating func takeOwnership() {
        guard self == .idle else { return }
        self = .owned
    }

    /// Suppress writes while a restore runs. Non-owners are ignored.
    mutating func beginRestore() {
        guard self != .idle else { return }
        self = .restoring
    }

    /// Complete a restore. Ignored unless a restore was actually started, so a
    /// non-owner can never be armed by a stray callback.
    mutating func finishRestore(succeeded: Bool) {
        guard self == .restoring else { return }
        self = succeeded ? .armed : .failed
    }

    /// Arm without a restore, for the case where there is nothing to lose: the
    /// board file is missing or empty. Allowed after a failed restore too —
    /// there is no persisted board left to protect.
    mutating func armForFreshBoard() {
        guard self == .owned || self == .failed else { return }
        self = .armed
    }

    /// Release the lease. Everything after this point is read-only.
    mutating func relinquish() { self = .idle }
}
