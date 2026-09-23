import Foundation

/// Delivers values to an async `sink` one at a time, in the order they were
/// sent: one `AsyncStream` drained by a single task. A `Task` per value
/// would not: unstructured tasks start in no guaranteed order, so "nil
/// then A" could land as "A then nil".
final class LeoOrderedRelay<Value: Sendable>: Sendable {
    private let continuation: AsyncStream<Value>.Continuation
    private let drain: Task<Void, Never>

    init(sink: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        self.continuation = continuation
        drain = Task {
            for await value in stream { await sink(value) }
        }
    }

    deinit { continuation.finish() }

    func send(_ value: Value) {
        continuation.yield(value)
    }

    /// Stops accepting values and waits until every value already sent has
    /// been delivered.
    func finish() async {
        continuation.finish()
        await drain.value
    }
}
