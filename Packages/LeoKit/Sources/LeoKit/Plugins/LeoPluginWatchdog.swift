import Foundation

/// One reading of a host process's resource use.
public struct LeoPluginUsage: Equatable, Sendable {
    /// User + system CPU time, in seconds.
    public let cpuSeconds: Double
    /// `ri_phys_footprint`, in bytes.
    public let footprintBytes: UInt64

    public init(cpuSeconds: Double, footprintBytes: UInt64) {
        self.cpuSeconds = cpuSeconds
        self.footprintBytes = footprintBytes
    }

    /// `proc_pid_rusage` reports CPU time in mach ticks, which are not
    /// nanoseconds on Apple Silicon; convert with `mach_timebase_info`.
    public static func seconds(fromMachTicks ticks: UInt64, numer: UInt32, denom: UInt32) -> Double {
        guard denom != 0 else { return 0 }
        return Double(ticks) * Double(numer) / Double(denom) / 1_000_000_000
    }
}

public enum LeoPluginWatchdogVerdict: Equatable, Sendable {
    case ok
    /// SIGKILL the host; the owner reports it as a crash with this reason.
    case kill(reason: String)
}

/// Resource watchdog for one plugin host. Pure policy: the owner polls for the
/// helper's whole life (every ``pollInterval``), reads usage through the
/// injected closure, and acts on the verdict.
///
/// * CPU in a handler: a handler may use 2 s of CPU measured from when it
///   started running. Wall time spent waiting on the app costs nothing.
///   Handlers run one at a time in the host, so queued ones get a fresh
///   baseline when the one ahead finishes.
/// * CPU while idle: with no handler pending, growth above
///   ``idleCPUBudgetSeconds`` per ``idleCPUWindow`` is a background loop
///   (a promise chain or timer the plugin keeps alive) and is killed.
/// * Memory: `phys_footprint` above 256 MiB, read at most once per second and
///   immediately whenever a handler finishes, in a handler or not. A plugin
///   that allocates in a fast handler and returns is caught by the `done` check.
///
/// Polling means a runaway can overshoot its budget by up to one interval.
public struct LeoPluginWatchdog {
    public static let pollInterval: TimeInterval = 0.25
    public static let cpuBudgetSeconds: Double = 2
    public static let memoryLimitBytes: UInt64 = 256 * 1_048_576
    public static let memoryCheckInterval: TimeInterval = 1
    /// CPU seconds the helper may burn per idle window with no handler pending.
    public static let idleCPUBudgetSeconds: Double = 0.5
    public static let idleCPUWindow: TimeInterval = 1
    /// Smallest idle allowance, so a tiny gap can't turn timer noise into a kill.
    public static let idleCPUFloorSeconds: Double = 0.05

    private let readUsage: () -> LeoPluginUsage?
    private let cpuBudgetSeconds: Double
    private let memoryLimitBytes: UInt64
    private let memoryCheckInterval: TimeInterval
    private let idleCPUBudgetSeconds: Double
    private let idleCPUWindow: TimeInterval
    private var pending = 0
    private var cpuBaseline: Double = 0
    private var lastMemoryCheck: TimeInterval?
    /// Where the current idle window began: nil until a reading anchors it.
    private var idleBaseline: (cpu: Double, at: TimeInterval)?

    /// The limits default to the spec's; tests shrink them to run in milliseconds.
    public init(
        cpuBudgetSeconds: Double = LeoPluginWatchdog.cpuBudgetSeconds,
        memoryLimitBytes: UInt64 = LeoPluginWatchdog.memoryLimitBytes,
        memoryCheckInterval: TimeInterval = LeoPluginWatchdog.memoryCheckInterval,
        idleCPUBudgetSeconds: Double = LeoPluginWatchdog.idleCPUBudgetSeconds,
        idleCPUWindow: TimeInterval = LeoPluginWatchdog.idleCPUWindow,
        readUsage: @escaping () -> LeoPluginUsage?
    ) {
        self.cpuBudgetSeconds = cpuBudgetSeconds
        self.memoryLimitBytes = memoryLimitBytes
        self.memoryCheckInterval = memoryCheckInterval
        self.idleCPUBudgetSeconds = idleCPUBudgetSeconds
        self.idleCPUWindow = idleCPUWindow
        self.readUsage = readUsage
    }

    public var isHandlerInFlight: Bool { pending > 0 }

    /// A handler (or the bundle load) was handed to the host.
    public mutating func handlerStarted(at now: TimeInterval) {
        pending += 1
        guard pending == 1 else { return }
        cpuBaseline = readUsage()?.cpuSeconds ?? 0
        idleBaseline = nil
    }

    /// The host reported the oldest in-flight handler done. Checks memory right
    /// away: a handler can allocate and return between two scheduled reads.
    public mutating func handlerFinished(at now: TimeInterval) -> LeoPluginWatchdogVerdict {
        guard pending > 0 else { return .ok }
        pending -= 1
        let usage = readUsage()
        if pending > 0 {
            cpuBaseline = usage?.cpuSeconds ?? cpuBaseline
        } else if let usage {
            idleBaseline = (usage.cpuSeconds, now)
        }
        guard let usage else { return .ok }
        return memoryVerdict(usage, at: now, force: true) ?? .ok
    }

    /// Forget all in-flight work (the host exited).
    public mutating func reset() {
        pending = 0
        lastMemoryCheck = nil
        idleBaseline = nil
    }

    public mutating func poll(at now: TimeInterval) -> LeoPluginWatchdogVerdict {
        guard let usage = readUsage() else { return .ok }
        if pending > 0 {
            if usage.cpuSeconds - cpuBaseline > cpuBudgetSeconds {
                return .kill(reason: "handler used more than \(cpuBudgetSeconds.formatted()) s of CPU")
            }
        } else if let verdict = idleCPUVerdict(usage, at: now) {
            return verdict
        }
        return memoryVerdict(usage, at: now, force: false) ?? .ok
    }

    private mutating func idleCPUVerdict(_ usage: LeoPluginUsage, at now: TimeInterval) -> LeoPluginWatchdogVerdict? {
        guard let baseline = idleBaseline else {
            idleBaseline = (usage.cpuSeconds, now)
            return nil
        }
        guard now - baseline.at >= idleCPUWindow else { return nil }
        idleBaseline = (usage.cpuSeconds, now)
        // A rate, not an absolute: a poll gap stretched by App Nap or timer
        // coalescing earns proportionally more CPU before it counts as a loop.
        let gap = now - baseline.at
        let allowed = max(Self.idleCPUFloorSeconds, idleCPUBudgetSeconds / idleCPUWindow * gap)
        guard usage.cpuSeconds - baseline.cpu > allowed else { return nil }
        return .kill(reason: "host used CPU while idle (no handler running)")
    }

    private mutating func memoryVerdict(
        _ usage: LeoPluginUsage, at now: TimeInterval, force: Bool
    ) -> LeoPluginWatchdogVerdict? {
        if !force, let last = lastMemoryCheck, now - last < memoryCheckInterval { return nil }
        lastMemoryCheck = now
        guard usage.footprintBytes > memoryLimitBytes else { return nil }
        return .kill(reason: "host exceeded \(memoryLimitBytes / 1_048_576) MB of memory")
    }
}
