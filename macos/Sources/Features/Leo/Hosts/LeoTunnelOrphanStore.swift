import Darwin
import Foundation

/// A previous run's `LeoTunnel`, recorded so a future launch can reap it if the
/// app quit without a clean shutdown (crash, force-quit, etc.).
struct LeoTunnelOrphanRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let startTime: TimeInterval
    let socketPath: String
}

/// Persists at most one `LeoTunnelOrphanRecord` in `UserDefaults`. `reapAtLaunch`
/// must run before any tunnel is started this launch, so a leftover record always
/// describes a process this run has not touched yet -- otherwise a freshly
/// launched tunnel could be mistaken for (and killed as) its own orphan.
struct LeoTunnelOrphanStore {
    private let defaults: UserDefaults
    private let key: String
    private let fileManager: FileManager
    /// Serializes every read-then-write against this store's key: `record`,
    /// `clear(matching:)`, and the unlink+clear at the end of `reapAtLaunch`.
    /// Without it, a `record(_:)` call landing between a "does the stored
    /// value still match" check and the removal that follows it could delete
    /// (or unlink the socket of) a tunnel that just replaced the one being
    /// reaped. Never held across `inspector`/`signaller`/`sleep`, which are
    /// caller-supplied and may themselves call back into this store.
    private let lock = NSLock()

    init(defaults: UserDefaults, key: String = "leo.tunnel.orphan", fileManager: FileManager = .default) {
        self.defaults = defaults
        self.key = key
        self.fileManager = fileManager
    }

    func record(_ record: LeoTunnelOrphanRecord) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(try? JSONEncoder().encode(record), forKey: key)
    }

    func current() -> LeoTunnelOrphanRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LeoTunnelOrphanRecord.self, from: data)
    }

    /// Removes the stored record only if it still equals `record` -- a concurrent
    /// `record(_:)` call (a newer tunnel starting) may already have replaced it.
    func clear(matching record: LeoTunnelOrphanRecord) {
        lock.lock()
        defer { lock.unlock() }
        clearLocked(matching: record)
    }

    /// If the stored record's pid is still running with the same start time,
    /// SIGTERM it, give it up to 1s to exit, then SIGKILL if it's still around.
    /// A mismatched start time means the pid was recycled by an unrelated
    /// process: it is never signalled and the record is left untouched (there is
    /// nothing safe to reap). `inspector`/`signaller`/`sleep` are injected so
    /// tests can run this synchronously without real processes or real waits.
    func reapAtLaunch(
        inspector: (Int32) -> TimeInterval?,
        signaller: (Int32, Int32) -> Void,
        sleep: (Duration) -> Void = leoTunnelRealSleep
    ) {
        guard let record = current(), inspector(record.pid) == record.startTime else { return }
        signaller(record.pid, SIGTERM)
        sleep(.seconds(1))
        if inspector(record.pid) == record.startTime {
            signaller(record.pid, SIGKILL)
        }
        // A replacement tunnel may have been recorded while we were signalling;
        // atomically re-check-and-unlink so that race can only ever preserve
        // the replacement, never drop it.
        lock.lock()
        defer { lock.unlock() }
        guard current() == record else { return }
        try? fileManager.removeItem(atPath: record.socketPath)
        clearLocked(matching: record)
    }

    private func clearLocked(matching record: LeoTunnelOrphanRecord) {
        guard current() == record else { return }
        defaults.removeObject(forKey: key)
    }
}

func leoTunnelRealSleep(_ duration: Duration) {
    guard duration > .zero else { return }
    let seconds = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    Thread.sleep(forTimeInterval: seconds)
}

/// Real `reapAtLaunch` inspector: the process start time for `pid`, or `nil`
/// if it isn't running. Matches `LeoTunnel`'s own `startTime(of:)` so a
/// recorded orphan's start time can be compared against the live process --
/// a mismatch means the pid was recycled by an unrelated process.
func leoTunnelRealInspector(_ pid: Int32) -> TimeInterval? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard bytes == size else { return nil }
    return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
}

/// Real `reapAtLaunch` signaller: sends `signal` to `pid`.
func leoTunnelRealSignaller(_ pid: Int32, _ signal: Int32) {
    _ = Darwin.kill(pid, signal)
}
