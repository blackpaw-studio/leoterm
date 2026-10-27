import Foundation

/// Delivers values to an async `sink` one at a time, in the order they were
/// sent: one `AsyncStream` drained by a single task. A `Task` per value
/// would not: unstructured tasks start in no guaranteed order, so "nil
/// then A" could land as "A then nil".
final class LeoOrderedRelay<Value: Sendable>: Sendable {
    private enum Item: Sendable {
        case value(Value)
        /// Resumed by the drain once every value sent before it was handled.
        case barrier(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Item>.Continuation
    private let drain: Task<Void, Never>

    init(sink: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        self.continuation = continuation
        drain = Task {
            for await item in stream {
                switch item {
                case .value(let value): await sink(value)
                case .barrier(let barrier): barrier.resume()
                }
            }
        }
    }

    deinit { continuation.finish() }

    func send(_ value: Value) {
        continuation.yield(.value(value))
    }

    /// Returns once every value sent before this call has been handled,
    /// leaving the relay open; at once when it has finished.
    func settled() async {
        await withCheckedContinuation { barrier in
            if case .terminated = continuation.yield(.barrier(barrier)) { barrier.resume() }
        }
    }

    /// Stops accepting values and waits until every value already sent has
    /// been delivered.
    func finish() async {
        continuation.finish()
        await drain.value
    }
}
