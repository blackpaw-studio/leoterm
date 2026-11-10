import Foundation

/// Proof that a request was admitted. Hand it back to
/// ``LeoPluginRateLimiter/release(_:)`` when the request finishes (success,
/// failure or cancellation) so its in-flight slot frees.
public struct LeoPluginRateLimitPermit: Hashable, Sendable {
    fileprivate let limiter: ObjectIdentifier
    fileprivate let serial: UInt64
}

public enum LeoPluginRateLimitRejection: Equatable, Sendable {
    /// The per-window quota is spent; a slot frees after `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval)
    /// Too many requests are already running; retry once one completes.
    case tooManyInFlight
}

public enum LeoPluginRateLimitDecision: Equatable, Sendable {
    case granted(LeoPluginRateLimitPermit)
    case rejected(LeoPluginRateLimitRejection)
}

/// Per-plugin fetch limiter: a sliding window (default 60 requests per minute)
/// plus a cap on concurrent requests (default 4). Non-blocking: a request over
/// either limit is rejected, never queued, so a runaway plugin can't pile up work.
///
/// Thread-safe. The clock is injected (seconds on a monotonic timeline, e.g.
/// `ProcessInfo.systemUptime`) so tests never sleep.
public final class LeoPluginRateLimiter: @unchecked Sendable {
    public static let defaultMaxPerWindow = 60
    public static let defaultWindow: TimeInterval = 60
    public static let defaultMaxInFlight = 4
    public static let systemClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private let maxPerWindow: Int
    private let window: TimeInterval
    private let maxInFlight: Int
    private let now: @Sendable () -> TimeInterval

    private let lock = NSLock()
    private var granted: [TimeInterval] = []   // admission times still inside the window
    private var inFlight: Set<UInt64> = []
    private var nextSerial: UInt64 = 0

    public init(
        maxPerWindow: Int = LeoPluginRateLimiter.defaultMaxPerWindow,
        window: TimeInterval = LeoPluginRateLimiter.defaultWindow,
        maxInFlight: Int = LeoPluginRateLimiter.defaultMaxInFlight,
        now: @escaping @Sendable () -> TimeInterval = LeoPluginRateLimiter.systemClock
    ) {
        precondition(maxPerWindow > 0 && maxInFlight > 0 && window > 0, "limits must be positive")
        self.maxPerWindow = maxPerWindow
        self.window = window
        self.maxInFlight = maxInFlight
        self.now = now
    }

    /// Admits a request or says why not. Only admitted requests count against
    /// the window, so rejections can't extend a plugin's own lockout.
    public func acquire() -> LeoPluginRateLimitDecision {
        lock.withLock {
            let current = now()
            granted.removeAll { current - $0 >= window }
            if granted.count >= maxPerWindow {
                let oldest = granted.min() ?? current
                return .rejected(.rateLimited(retryAfter: max(0, oldest + window - current)))
            }
            if inFlight.count >= maxInFlight { return .rejected(.tooManyInFlight) }
            granted.append(current)
            nextSerial += 1
            inFlight.insert(nextSerial)
            return .granted(LeoPluginRateLimitPermit(limiter: ObjectIdentifier(self), serial: nextSerial))
        }
    }

    /// Frees the permit's in-flight slot. Idempotent, and ignores permits from
    /// other limiters.
    public func release(_ permit: LeoPluginRateLimitPermit) {
        guard permit.limiter == ObjectIdentifier(self) else { return }
        lock.withLock { _ = inFlight.remove(permit.serial) }
    }
}
