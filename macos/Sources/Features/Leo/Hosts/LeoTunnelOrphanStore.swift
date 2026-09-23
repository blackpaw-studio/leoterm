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
    private let socketOwner: uid_t
    /// Records pointing in here were written by a pre-B-021 build, which
    /// never locks its path; see `reapAtLaunch`.
    private let legacySocketDirectory: URL
    /// Serializes every read-then-write against this store's key: `record`,
    /// `clear(matching:)`, and the unlink+clear at the end of `reapAtLaunch`.
    /// Without it, a `record(_:)` call landing between a "does the stored
    /// value still match" check and the removal that follows it could delete
    /// (or unlink the socket of) a tunnel that just replaced the one being
    /// reaped. Never held across `inspector`/`signaller`/`sleep`, which are
    /// caller-supplied and may themselves call back into this store.
    private let lock = NSLock()

    init(
        defaults: UserDefaults,
        key: String = "leo.tunnel.orphan",
        socketOwner: uid_t = geteuid(),
        legacySocketDirectory: URL = LeoTunnelOrphanStore.defaultLegacySocketDirectory
    ) {
        self.defaults = defaults
        self.key = key
        self.socketOwner = socketOwner
        self.legacySocketDirectory = legacySocketDirectory
    }

    /// `~/.leo/state/leoterm/`, where the forwarded socket lived before B-021.
    static let defaultLegacySocketDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".leo/state/leoterm", isDirectory: true)

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

    /// Reaps a previous run's tunnel -- never one from a pre-B-021 record
    /// (see `dropLegacy`) and only one whose socket path lock
    /// (`LeoTunnelSocketLock`, D-049) this call can take. A held lock means
    /// another running copy of the app owns that path, so the record
    /// describes its live tunnel: nothing is signalled, removed or cleared.
    ///
    /// With the lock held: if the stored record's pid is still running with
    /// the same start time, SIGTERM it, give it up to 1s to exit, then
    /// SIGKILL if it's still around. A mismatched start time means the pid
    /// was recycled by an unrelated process: it is never signalled and the
    /// record is left untouched (there is nothing safe to reap). A pid that
    /// isn't running at all has its record cleared. Either way the socket
    /// at the path goes if it's this user's, without a probe (the lock
    /// already proves nobody live owns it).
    ///
    /// The start time is re-read immediately before each signal, the
    /// SIGKILL escalation included. Darwin has no way to signal a process
    /// by identity rather than pid, so a pid that exits and is recycled
    /// between that read and the `kill` is the one window left -- a few
    /// instructions wide, and only for a process that happened to exit on
    /// its own at that exact moment. `inspector`/`signaller`/`sleep` are
    /// injected so tests can run this synchronously without real processes
    /// or real waits.
    func reapAtLaunch(
        inspector: (Int32) -> TimeInterval?,
        signaller: (Int32, Int32) -> Void,
        sleep: (Duration) -> Void = leoTunnelRealSleep
    ) {
        guard let record = current() else { return }
        guard !isLegacy(record) else {
            dropLegacy(record)
            return
        }
        guard let pathLock = try? LeoTunnelSocketLock.acquire(for: record.socketPath, owner: socketOwner) else { return }
        defer { pathLock.release() }
        switch inspector(record.pid) {
        case nil:
            // Already gone (e.g. the machine rebooted): nothing to signal,
            // but its forward may still be lying there.
            removeSocketAndClear(record)
        case record.startTime:
            signaller(record.pid, SIGTERM)
            sleep(.seconds(1))
            if inspector(record.pid) == record.startTime {
                signaller(record.pid, SIGKILL)
            }
            removeSocketAndClear(record)
        default:
            return
        }
    }

    private func isLegacy(_ record: LeoTunnelOrphanRecord) -> Bool {
        URL(fileURLWithPath: record.socketPath).deletingLastPathComponent().standardizedFileURL.path
            == legacySocketDirectory.standardizedFileURL.path
    }

    /// A pre-B-021 record: its build never locked the path, so a live copy
    /// of it can't be told from an orphan. Its process is never signalled
    /// (a leftover ssh from a crashed pre-B-021 run is harmless and stays),
    /// the record is cleared, and the socket goes only if the probe finds
    /// it dead. No lock file is created in the old directory.
    private func dropLegacy(_ record: LeoTunnelOrphanRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard current() == record else { return }
        LeoControlSocket.removeIfStale(record.socketPath, owner: socketOwner)
        clearLocked(matching: record)
    }

    /// A replacement tunnel may have been recorded while we were signalling;
    /// atomically re-check-and-unlink so that race can only ever preserve the
    /// replacement, never drop it. The record may predate B-021 and point
    /// into `~/.leo/state/leoterm/`; only a socket this user owns at the
    /// recorded path goes -- a file or another user's socket stays.
    private func removeSocketAndClear(_ record: LeoTunnelOrphanRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard current() == record else { return }
        LeoControlSocket.removeOwnedSocket(record.socketPath, owner: socketOwner)
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
