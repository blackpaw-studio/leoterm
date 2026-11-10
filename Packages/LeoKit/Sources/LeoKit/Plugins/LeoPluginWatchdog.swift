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

/// Resource watchdog for one plugin host. Pure policy: the owner polls
/// (every ``pollInterval`` while a handler is in flight), reads usage through
/// the injected closure, and acts on the verdict.
///
/// * CPU: a handler may use 2 s of CPU measured from when it started running.
///   Wall time spent waiting on the app costs nothing. Handlers run one at a
///   time in the host, so queued ones get a fresh baseline when the one ahead
///   finishes.
/// * Memory: `phys_footprint` above 256 MiB, read at most once per second.
///
/// Polling means a runaway can overshoot its budget by up to one interval.
public struct LeoPluginWatchdog {
    public static let pollInterval: TimeInterval = 0.25
    public static let cpuBudgetSeconds: Double = 2
    public static let memoryLimitBytes: UInt64 = 256 * 1_048_576
    public static let memoryCheckInterval: TimeInterval = 1

    private let readUsage: () -> LeoPluginUsage?
    private var pending = 0
    private var cpuBaseline: Double = 0
    private var lastMemoryCheck: TimeInterval?

    public init(readUsage: @escaping () -> LeoPluginUsage?) {
        self.readUsage = readUsage
    }

    public var isHandlerInFlight: Bool { pending > 0 }

    /// A handler (or the bundle load) was handed to the host.
    public mutating func handlerStarted(at now: TimeInterval) {
        pending += 1
        guard pending == 1 else { return }
        cpuBaseline = readUsage()?.cpuSeconds ?? 0
        lastMemoryCheck = nil
    }

    /// The host reported the oldest in-flight handler done.
    public mutating func handlerFinished(at now: TimeInterval) {
        guard pending > 0 else { return }
        pending -= 1
        if pending > 0 { cpuBaseline = readUsage()?.cpuSeconds ?? cpuBaseline }
    }

    /// Forget all in-flight work (the host exited).
    public mutating func reset() {
        pending = 0
        lastMemoryCheck = nil
    }

    public mutating func poll(at now: TimeInterval) -> LeoPluginWatchdogVerdict {
        guard pending > 0, let usage = readUsage() else { return .ok }
        if usage.cpuSeconds - cpuBaseline > Self.cpuBudgetSeconds {
            return .kill(reason: "handler used more than \(Int(Self.cpuBudgetSeconds)) s of CPU")
        }
        if let last = lastMemoryCheck, now - last < Self.memoryCheckInterval { return .ok }
        lastMemoryCheck = now
        if usage.footprintBytes > Self.memoryLimitBytes {
            return .kill(reason: "host exceeded \(Self.memoryLimitBytes / 1_048_576) MB of memory")
        }
        return .ok
    }
}
