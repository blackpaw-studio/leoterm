import Foundation

/// Crash policy for one plugin host: a pure state machine, one per plugin.
///
/// Restart after 1 s on the first crash, 5 s on the second, 30 s on the third
/// (only reachable if `maxCrashes` is raised above the default). The `maxCrashes`th
/// crash inside `window` disables the plugin until ``reenable()``. Only crashes
/// inside the window count, so a plugin that stays up long enough starts over.
///
/// The owner (manager) performs the restart; this type only decides. Times are
/// seconds on one monotonic timeline, passed in so tests never sleep.
public struct LeoPluginSupervisor: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case restart(after: TimeInterval)
        case disable(reason: String)
    }

    public enum State: Equatable, Sendable {
        case running
        case disabled(reason: String)
    }

    public static let defaultBackoff: [TimeInterval] = [1, 5, 30]
    public static let defaultMaxCrashes = 3
    public static let defaultWindow: TimeInterval = 300

    public private(set) var state: State = .running
    private var crashTimes: [TimeInterval] = []
    private let backoff: [TimeInterval]
    private let maxCrashes: Int
    private let window: TimeInterval

    public init(
        backoff: [TimeInterval] = defaultBackoff,
        maxCrashes: Int = defaultMaxCrashes,
        window: TimeInterval = defaultWindow
    ) {
        self.backoff = backoff.isEmpty ? Self.defaultBackoff : backoff
        self.maxCrashes = max(1, maxCrashes)
        self.window = window
    }

    /// Records a host crash and says what to do about it.
    public mutating func recordCrash(reason: String, at now: TimeInterval) -> Decision {
        if case .disabled(let existing) = state { return .disable(reason: existing) }
        crashTimes = crashTimes.filter { now - $0 <= window } + [now]
        guard crashTimes.count < maxCrashes else {
            state = .disabled(reason: reason)
            return .disable(reason: reason)
        }
        return .restart(after: backoff[min(crashTimes.count, backoff.count) - 1])
    }

    /// The user re-enabled a disabled plugin: forget its crash history.
    public mutating func reenable() {
        state = .running
        crashTimes = []
    }
}
