import Foundation

/// A first-in-first-out async mutex: runs one body at a time in arrival order.
/// A body waiting its turn can be cancelled and then never runs.
@MainActor
final class LeoBrowserSerialGate {
    private(set) var isBusy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    var waitingCount: Int { waiters.count }

    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        // A waiter cancelled after it was handed the turn is resumed normally;
        // it must not run.
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    /// Hands the turn straight to the next waiter, so `isBusy` never drops between them.
    private func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
