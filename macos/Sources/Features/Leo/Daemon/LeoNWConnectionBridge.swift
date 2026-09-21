import Darwin
import Foundation
import Network

/// Bridges a single-use `NWConnection` over a unix-domain socket to Swift
/// concurrency. One instance == one connection == one request or one
/// stream, each on its own dedicated serial queue (a shared queue would let
/// one misbehaving connection starve every other connection's callbacks),
/// and every continuation this type resumes is guarded so overlapping
/// state transitions (`.ready`/`.failed`/`.cancelled`/`.waiting`) can only
/// resume it once.
final class LeoNWConnectionBridge: @unchecked Sendable {
    enum CancelReason: Sendable { case task, timeout }

    /// Spurious empty, non-error, non-complete `receive` completions are
    /// re-issued rather than surfaced (see `receiveLoop`); bound the streak
    /// so a connection that never stops producing them can't spin forever.
    private static let maxConsecutiveEmptyReceives = 32

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var cancelReason: CancelReason?
    /// Set (under `lock`, together with calling `connection.start()`) once
    /// `connect()` has started the connection. Calling `connection.cancel()`
    /// before `start()` never delivers a `.cancelled` state transition (and
    /// a subsequent `start()` is a no-op), so `cancel(reason:)` must not
    /// touch the connection until it's actually started. `started` and the
    /// `connection.start()` call happen inside the same critical section as
    /// the `cancelReason` check that guards it, so there's no window
    /// between "decided to start" and "actually called start()" for a
    /// concurrent `cancel(reason:)` to fall into.
    private var started = false
    /// Set once a `receive` completion has reported `isComplete == true` --
    /// whether or not it arrived together with trailing content. NWConnection
    /// only ever delivers one such final read; `receiveChunk` consults this
    /// before issuing another `connection.receive` to avoid the transport
    /// error a second one can produce (see `receiveChunk`'s doc comment).
    private var finalReadDelivered = false

    init(socketPath: String) throws {
        let address = sockaddr_un()
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard socketPath.utf8.count <= limit else {
            throw LeoDaemonError.transport("Socket path is too long")
        }
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        queue = DispatchQueue(label: "leo.daemon.nwconnection")
    }

    /// Connects and waits for `.ready`. Throws immediately -- no automatic
    /// retry -- on `.waiting`/`.failed`, and `CancellationError`/`.timeout`
    /// if `cancel(reason:)` raced the connect. `beforeStart`, awaited
    /// before the connect proper begins, is a test-only seam for
    /// deterministically racing a cancel against the start of `connect()`.
    func connect(beforeStart: (@Sendable () async -> Void)? = nil) async throws {
        await beforeStart?()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let reason = cancelReason {
                lock.unlock()
                continuation.resume(throwing: Self.error(for: reason))
                return
            }
            readyContinuation = continuation
            started = true
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state: state) }
            connection.start(queue: queue)
            lock.unlock()
        }
    }

    /// Sends `data`. `isFinal` controls whether this also half-closes the
    /// connection's write side (an `NWConnection.ContentContext.finalMessage`
    /// send) -- callers should keep this `false` in every production path:
    /// `LeoHTTPRequest.serialized()` already sends `Connection: close`, so
    /// read-to-EOF terminates the response without an explicit FIN, and a
    /// FIN sent through an SSH `-L` tunnel that's proxying this socket can
    /// propagate and truncate the *server's* read of a differently-timed
    /// request on the same tunnel. It exists as a parameter (rather than
    /// being hardcoded false) purely so a test can exercise the half-close
    /// framing explicitly.
    func send(_ data: Data, isFinal: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context: NWConnection.ContentContext = isFinal ? .finalMessage : .defaultMessage
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let error else { continuation.resume(); return }
                continuation.resume(throwing: self?.terminalError(fallback: error) ?? Self.mapError(error))
            })
        }
    }

    /// Reads the next chunk of the response. Returns `nil` on a clean EOF.
    /// `onFinalReadObserved`, invoked synchronously right before resuming
    /// a completion that reported `isComplete == true` (whether or not it
    /// arrived together with content), is a test-only seam (see
    /// `connect(beforeStart:)` above for the same pattern) for
    /// deterministically racing a second `receiveChunk` call against the
    /// exact instant NWConnection considers its one and only final read
    /// delivered, rather than relying on timing luck.
    func receiveChunk(maxLength: Int, onFinalReadObserved: (@Sendable () -> Void)? = nil) async throws -> Data? {
        // NWConnection delivers exactly one final read: once that's been
        // observed (whether or not it arrived with trailing content --
        // see the two `recordFinalReadDelivered()` call sites below), any
        // further call must not issue another `connection.receive` --
        // NWConnection can reject a second one with a real transport
        // error (observed as `.transport("Socket is not connected")`)
        // instead of the clean repeat-EOF a caller unaware of the
        // coalesced FIN would expect from calling `receiveChunk` again.
        if recordedFinalReadDelivered() {
            if let reason = recordedCancelReason() { throw Self.error(for: reason) }
            return nil
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            receiveLoop(maxLength: maxLength, emptyStreak: 0, onFinalReadObserved: onFinalReadObserved, continuation: continuation)
        }
    }

    private func receiveLoop(
        maxLength: Int, emptyStreak: Int, onFinalReadObserved: (@Sendable () -> Void)?,
        continuation: CheckedContinuation<Data?, Error>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { [weak self] content, _, isComplete, error in
            guard let self else { continuation.resume(returning: nil); return }
            if let error {
                continuation.resume(throwing: self.terminalError(fallback: error))
                return
            }
            if let content, !content.isEmpty {
                if isComplete {
                    self.recordFinalReadDelivered()
                    onFinalReadObserved?()
                }
                continuation.resume(returning: content)
                return
            }
            if isComplete {
                self.recordFinalReadDelivered()
                onFinalReadObserved?()
                // A deliberate `cancel(reason:)` (timeout/task) often
                // surfaces here as a clean isComplete-with-no-error
                // completion rather than an NWError -- classify it the same
                // way a real error from this connection would be, so a
                // timed-out stream throws `.timeout` instead of looking
                // like a normal EOF.
                if let reason = self.recordedCancelReason() {
                    continuation.resume(throwing: Self.error(for: reason))
                } else {
                    continuation.resume(returning: nil)
                }
                return
            }
            // No content, not complete, no error: a spurious wake:
            // NWConnection can call the completion handler this way
            // without new data. Resuming with an empty chunk here would
            // let callers busy-spin on it, so re-issue the receive instead
            // -- unless a cancel is already in flight, or this has now
            // happened too many times in a row, in which case bail rather
            // than looping against a dying/misbehaving connection.
            if let reason = self.recordedCancelReason() {
                continuation.resume(throwing: Self.error(for: reason))
                return
            }
            let nextStreak = emptyStreak + 1
            guard nextStreak <= Self.maxConsecutiveEmptyReceives else {
                continuation.resume(throwing: LeoDaemonError.transport("Too many empty reads from connection"))
                return
            }
            self.receiveLoop(maxLength: maxLength, emptyStreak: nextStreak, onFinalReadObserved: onFinalReadObserved, continuation: continuation)
        }
    }

    /// Tears down the connection. Safe to call more than once (e.g. from a
    /// timeout watchdog and then a normal-completion `defer`).
    func cancel(reason: CancelReason) {
        lock.lock()
        if cancelReason == nil { cancelReason = reason }
        let shouldCancelConnection = started
        lock.unlock()
        if shouldCancelConnection { connection.cancel() }
    }

    func recordedCancelReason() -> CancelReason? {
        lock.lock(); defer { lock.unlock() }
        return cancelReason
    }

    private func recordFinalReadDelivered() {
        lock.lock(); defer { lock.unlock() }
        finalReadDelivered = true
    }

    private func recordedFinalReadDelivered() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return finalReadDelivered
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            resumeReady(.success(()))
        case .waiting(let error), .failed(let error):
            // Unix-domain connect failures (ENOENT, ECONNREFUSED) surface
            // as `.waiting`, not `.failed` -- NWConnection's automatic
            // path-recovery logic exists for flaky network links and will
            // otherwise sit in `.waiting` indefinitely retrying a socket
            // that will never come back. Local sockets have no such
            // recovery story, so `.waiting` is treated as a terminal
            // failure, same as `.failed`.
            resumeReady(.failure(terminalError(fallback: error)))
        case .cancelled:
            resumeReady(.failure(terminalError(fallback: nil)))
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func resumeReady(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            connection.cancel()
            continuation.resume(throwing: error)
        }
    }

    /// Classifies a terminal error using the recorded cancel reason (if
    /// this connection was torn down deliberately) or the raw `NWError`
    /// otherwise.
    private func terminalError(fallback: NWError?) -> Error {
        guard let reason = recordedCancelReason() else {
            if let fallback { return Self.mapError(fallback) }
            return LeoDaemonError.transport("Connection closed")
        }
        return Self.error(for: reason)
    }

    private static func error(for reason: CancelReason) -> Error {
        switch reason {
        case .task: return CancellationError()
        case .timeout: return LeoDaemonError.timeout
        }
    }

    private static func mapError(_ error: NWError) -> LeoDaemonError {
        if case .posix(let code) = error {
            if code == .ETIMEDOUT { return .timeout }
            return .transport(String(cString: strerror(code.rawValue)))
        }
        return .transport(String(describing: error))
    }
}
