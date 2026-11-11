import Foundation

/// The one-shot hand-off between a sheet and the code awaiting its answer.
/// Whatever ends the sheet (a button, the window closing, the awaiting task
/// being cancelled) calls `finish`; the first call wins, runs `cleanup` once
/// and resumes the waiter. The waiter can never be left hanging, which is what
/// would leak one of a plugin's confirmation slots.
@MainActor final class LeoPluginSheetRendezvous<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var outcome: Value?
    private(set) var isDone = false
    private var cleanup: (() -> Void)?

    /// Runs once when the sheet ends, or at once if it already has.
    func onFinish(_ cleanup: @escaping () -> Void) {
        guard !isDone else { return cleanup() }
        self.cleanup = cleanup
    }

    func finish(_ value: Value?) {
        guard !isDone else { return }
        isDone = true
        outcome = value
        cleanup?()
        cleanup = nil
        continuation?.resume(returning: value)
        continuation = nil
    }

    /// Suspends until `finish`. Cancelling the awaiting task finishes with nil.
    func wait() async -> Value? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                if isDone { continuation.resume(returning: outcome) } else { self.continuation = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }
}
