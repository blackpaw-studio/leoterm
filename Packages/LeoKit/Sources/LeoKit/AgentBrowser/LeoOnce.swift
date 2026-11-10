import Foundation

/// A result that settles once: the first `resume` wins and later ones are
/// dropped, so racing outcomes (an answer against a cancellation) can never
/// resume a continuation twice. A result that lands before anyone waits is
/// kept for the waiter.
@MainActor
public final class LeoOnce<T> {
    private var result: Result<T, any Error>?
    private var waiter: CheckedContinuation<T, any Error>?

    public init() {}

    /// Waits for the first result. One waiter at most.
    public func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    public func resume(with result: Result<T, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(with: result)
        waiter = nil
    }
}
