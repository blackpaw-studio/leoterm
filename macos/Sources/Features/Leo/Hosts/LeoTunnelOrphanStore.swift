import Darwin
import Foundation

/// A previous run's `LeoTunnel`, recorded so a future launch can reap it if the
/// app quit without a clean shutdown (crash, force-quit, etc.).
struct LeoTunnelOrphanRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let startTime: TimeInterval
    let socketPath: String
}

/// Persists one `LeoTunnelOrphanRecord` per tunnel socket path in
/// `UserDefaults`, each under its own key (`<key>.<socket path>`), so copies
/// of the app connected to different hosts never overwrite each other's
/// record -- and no read-modify-write of a shared value can drop one.
/// A record is written by `LeoTunnel.onLaunch`, which runs only after the
/// tunnel has taken that path's `LeoTunnelSocketLock`. `reapAtLaunch` must
/// run before any tunnel is started this launch, so a leftover record always
/// describes a process this run has not touched yet -- otherwise a freshly
/// launched tunnel could be mistaken for (and killed as) its own orphan.
struct LeoTunnelOrphanStore {
    private let defaults: UserDefaults
    /// Also where builds before per-path records kept their single record;
    /// it's read (and cleared) like any other.
    private let key: String
    private let socketOwner: uid_t
    /// Records pointing in here were written by a pre-B-021 build, which
    /// never locks its path; see `reapAtLaunch`.
    private let legacySocketDirectory: URL
    /// Serializes every read-then-write against this store's keys: `record`,
    /// `clear(matching:)`, and the unlink+clear at the end of a reap.
    /// Without it, a `record(_:)` call landing between a "does the stored
    /// value still match" check and the removal that follows it could delete
    /// (or unlink the socket of) a tunnel that just replaced the one being
    /// reaped. Never held across `inspector`/`signaller`/`sleep`, which are
    /// caller-supplied and may themselves call back into this store.
    private let lock = NSLock()

    /// How long each signal gets to take effect, and how often the pid is
    /// re-checked meanwhile.
    static let exitWait: Duration = .seconds(1)
    static let exitPoll: Duration = .milliseconds(50)

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
        defaults.set(try? JSONEncoder().encode(record), forKey: storageKey(for: record.socketPath))
    }

    /// Every stored record, the pre-per-path single record included.
    func records() -> [LeoTunnelOrphanRecord] {
        let prefix = key + "."
        let perPath = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.sorted()
        return ([key] + perPath).compactMap(decode)
    }

    /// Removes the stored record only if it still equals `record` -- a concurrent
    /// `record(_:)` call (a newer tunnel starting) may already have replaced it.
    func clear(matching record: LeoTunnelOrphanRecord) {
        lock.lock()
        defer { lock.unlock() }
        clearLocked(matching: record)
    }

    /// Reaps previous runs' tunnels, one record at a time -- never one from
    /// a pre-B-021 record (see `dropLegacy`) and only one whose socket path
    /// lock (`LeoTunnelSocketLock`, D-049) this call can take. A held lock
    /// means another running copy of the app owns that path, so the record
    /// describes its live tunnel: nothing is signalled, removed or cleared.
    ///
    /// With the lock held: a recorded pid still running with the same start
    /// time gets SIGTERM, then SIGKILL, each followed by up to `exitWait` for
    /// it to be gone. Only once it's confirmed gone (or was never running) is
    /// the record cleared and the socket at the path removed if it's this
    /// user's, without a probe (the lock proves nobody live owns it). A
    /// mismatched start time means the pid was recycled by an unrelated
    /// process: it is never signalled and the record is left untouched.
    ///
    /// A process still alive after SIGKILL, or a `kill` that failed with
    /// anything but ESRCH, proves nothing is gone: record and socket stay,
    /// and that path's lock is returned instead of released. The caller
    /// holds it for the rest of the run, so the path reads as in use rather
    /// than starting a second tunnel beside a process that may still hold it.
    ///
    /// The start time is re-read immediately before each signal. Darwin has
    /// no way to signal a process by identity rather than pid, so a pid that
    /// exits and is recycled between that read and the `kill` is the one
    /// window left -- a few instructions wide, and only for a process that
    /// happened to exit on its own at that exact moment.
    /// `inspector`/`signaller` (returns 0 or an errno)/`sleep` are injected
    /// so tests can run this synchronously without real processes or waits.
    @discardableResult
    func reapAtLaunch(
        inspector: (Int32) -> TimeInterval?,
        signaller: (Int32, Int32) -> Int32,
        sleep: (Duration) -> Void = leoTunnelRealSleep
    ) -> [LeoTunnelSocketLock] {
        records().compactMap { reap($0, inspector: inspector, signaller: signaller, sleep: sleep) }
    }

    /// The path's lock when its process couldn't be confirmed gone.
    private func reap(
        _ record: LeoTunnelOrphanRecord,
        inspector: (Int32) -> TimeInterval?,
        signaller: (Int32, Int32) -> Int32,
        sleep: (Duration) -> Void
    ) -> LeoTunnelSocketLock? {
        guard !isLegacy(record) else {
            dropLegacy(record)
            return nil
        }
        guard let pathLock = try? LeoTunnelSocketLock.acquire(for: record.socketPath, owner: socketOwner) else { return nil }
        switch inspector(record.pid) {
        case nil:
            // Already gone (e.g. the machine rebooted): nothing to signal,
            // but its forward may still be lying there.
            removeSocketAndClear(record)
        case record.startTime:
            guard stop(record, inspector: inspector, signaller: signaller, sleep: sleep) else { return pathLock }
            removeSocketAndClear(record)
        default:
            break
        }
        pathLock.release()
        return nil
    }

    /// True once `record`'s process is confirmed gone.
    private func stop(
        _ record: LeoTunnelOrphanRecord,
        inspector: (Int32) -> TimeInterval?,
        signaller: (Int32, Int32) -> Int32,
        sleep: (Duration) -> Void
    ) -> Bool {
        for signal in [SIGTERM, SIGKILL] {
            guard inspector(record.pid) == record.startTime else { return true }
            let result = signaller(record.pid, signal)
            guard result == 0 || result == ESRCH else { return false }
            var waited: Duration = .zero
            while inspector(record.pid) == record.startTime, waited < Self.exitWait {
                sleep(Self.exitPoll)
                waited += Self.exitPoll
            }
        }
        return inspector(record.pid) != record.startTime
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
        guard isStored(record) else { return }
        LeoControlSocket.removeIfStale(record.socketPath, owner: socketOwner)
        clearLocked(matching: record)
    }

    /// A replacement tunnel may have been recorded while we were signalling;
    /// atomically re-check-and-unlink so that race can only ever preserve the
    /// replacement, never drop it. Only a socket this user owns at the
    /// recorded path goes -- a file or another user's socket stays.
    private func removeSocketAndClear(_ record: LeoTunnelOrphanRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard isStored(record) else { return }
        LeoControlSocket.removeOwnedSocket(record.socketPath, owner: socketOwner)
        clearLocked(matching: record)
    }

    private func storageKey(for socketPath: String) -> String { "\(key).\(socketPath)" }

    private func keys(for record: LeoTunnelOrphanRecord) -> [String] { [storageKey(for: record.socketPath), key] }

    private func decode(_ storageKey: String) -> LeoTunnelOrphanRecord? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(LeoTunnelOrphanRecord.self, from: data)
    }

    private func isStored(_ record: LeoTunnelOrphanRecord) -> Bool {
        keys(for: record).contains { decode($0) == record }
    }

    private func clearLocked(matching record: LeoTunnelOrphanRecord) {
        for storageKey in keys(for: record) where decode(storageKey) == record {
            defaults.removeObject(forKey: storageKey)
        }
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
func leoTunnelRealSignaller(_ pid: Int32, _ signal: Int32) -> Int32 {
    Darwin.kill(pid, signal) == 0 ? 0 : errno
}
