import Dispatch
import Foundation
import LeoKit

/// Guards the host's read source against a request flood: pauses reading while
/// too many requests are waiting for the app's main queue (the helper then
/// blocks on a full socket buffer and stops producing), resumes as the queue
/// drains, and, once closed, makes anything still queued get dropped.
///
/// Callable from any queue. Dispatch sources must not be released while
/// suspended, so ``close()`` resumes before it cancels.
final class LeoPluginReadThrottle: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var backpressure: LeoPluginBackpressure
    private var isSuspended = false
    private var closed = false

    init(source: DispatchSourceRead, backpressure: LeoPluginBackpressure = LeoPluginBackpressure()) {
        self.source = source
        self.backpressure = backpressure
    }

    /// Requests read but not yet delivered or dropped.
    var outstanding: Int { lock.withLock { backpressure.outstanding } }

    /// True once the helper is terminating: queued requests must not be delivered.
    var isClosed: Bool { lock.withLock { closed } }

    /// A request was read; may pause the source.
    func requestEnqueued() {
        lock.withLock {
            guard backpressure.enqueued() == .suspend, !isSuspended, !closed else { return }
            source.suspend()
            isSuspended = true
        }
    }

    /// A request was delivered or dropped; may resume the source.
    func requestFinished() {
        lock.withLock {
            guard backpressure.delivered() == .resume, isSuspended, !closed else { return }
            source.resume()
            isSuspended = false
        }
    }

    /// Stops reading for good. Idempotent.
    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            if isSuspended {
                source.resume()
                isSuspended = false
            }
            source.cancel()
        }
    }
}
