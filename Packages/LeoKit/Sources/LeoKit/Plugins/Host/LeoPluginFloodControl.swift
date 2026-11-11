import Foundation

/// Per-handler cap on what plugin code may ask of the app. A plugin that loops
/// on `leo.log` / `leo.fetch` would otherwise queue unbounded work on the main
/// thread. The window is one handler invocation: the owner calls ``reset()``
/// on every `done` frame.
public struct LeoPluginRequestQuota: Equatable, Sendable {
    public static let defaultMaxRequests = 256
    public static let defaultMaxBytes = 8 * 1_048_576

    public let maxRequests: Int
    public let maxBytes: Int
    private var requests = 0
    private var bytes = 0

    public init(
        maxRequests: Int = LeoPluginRequestQuota.defaultMaxRequests,
        maxBytes: Int = LeoPluginRequestQuota.defaultMaxBytes
    ) {
        self.maxRequests = maxRequests
        self.maxBytes = maxBytes
    }

    /// Counts one request frame. Returns a user-visible reason when the
    /// handler has gone over either cap, nil otherwise.
    public mutating func record(requestBytes: Int) -> String? {
        requests += 1
        bytes += requestBytes
        if requests > maxRequests { return "handler sent more than \(maxRequests) requests" }
        if bytes > maxBytes { return "handler sent more than \(maxBytes / 1_048_576) MB of request bytes" }
        return nil
    }

    public mutating func reset() {
        requests = 0
        bytes = 0
    }
}

/// Counts requests read from the helper but not yet delivered to the app's
/// main queue, and says when to stop reading from the socket (the helper then
/// blocks on a full socket buffer) and when to start again.
public struct LeoPluginBackpressure: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none, suspend, resume
    }

    public static let defaultHighWater = 64
    public static let defaultLowWater = 32

    public private(set) var outstanding = 0
    private let highWater: Int
    private let lowWater: Int

    public init(
        highWater: Int = LeoPluginBackpressure.defaultHighWater,
        lowWater: Int = LeoPluginBackpressure.defaultLowWater
    ) {
        self.highWater = highWater
        self.lowWater = lowWater
    }

    /// A request was read and handed toward the main queue.
    public mutating func enqueued() -> Action {
        outstanding += 1
        return outstanding > highWater ? .suspend : .none
    }

    /// The main queue took (or dropped) one request.
    public mutating func delivered() -> Action {
        outstanding = max(0, outstanding - 1)
        return outstanding <= lowWater ? .resume : .none
    }
}
