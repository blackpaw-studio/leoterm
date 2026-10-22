import Darwin
import Foundation

/// A previous run's `LeoTunnel`, recorded so a future launch can reap it if the
/// app quit without a clean shutdown (crash, force-quit, etc.).
struct LeoTunnelOrphanRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let startTime: TimeInterval
    let socketPath: String
}

/// Persists one `LeoTunnelOrphanRecord` per forwarded socket in `UserDefaults`,
/// so every machine's tunnel is reapable after a crash. `reapAtLaunch`
/// must run before any tunnel is started this launch, so a leftover record always
/// describes a process this run has not touched yet -- otherwise a freshly
/// launched tunnel could be mistaken for (and killed as) its own orphan.
struct LeoTunnelOrphanStore {
    private let defaults: UserDefaults
    private let key: String
    private let fileManager: FileManager
    /// Records pointing in here were written by a pre-B-021 build; see
    /// `reapAtLaunch`.
    private let legacySocketDirectory: URL
    /// The authoritative records by socket path, shared by every copy of this
    /// struct. `lock` guards only this in-memory value and the decisions made
    /// on it (`record`, `clear(matching:)`, the unlink+clear at the end of
    /// `reapAtLaunch`), so a `record(_:)` landing between a "does the stored
    /// value still match" check and the removal that follows can never drop
    /// (or unlink the socket of) a tunnel that just replaced the one being
    /// reaped. `UserDefaults` is deliberately never touched while it is held:
    /// a write posts `didChangeNotification` synchronously, and any observer
    /// that waits on another thread (the main one, at quit) would turn the
    /// lock into a deadlock. Nor is it held across `inspector`/`signaller`/
    /// `sleep`, which are caller-supplied and may call back into this store.
    private final class Mirror: @unchecked Sendable {
        let lock = NSLock()
        var records: [String: LeoTunnelOrphanRecord] = [:]
    }

    private let mirror = Mirror()

    init(
        defaults: UserDefaults,
        key: String = "leo.tunnel.orphan",
        fileManager: FileManager = .default,
        legacySocketDirectory: URL = LeoTunnelOrphanStore.defaultLegacySocketDirectory
    ) {
        self.defaults = defaults
        self.key = key
        self.fileManager = fileManager
        self.legacySocketDirectory = legacySocketDirectory
        let stored = defaults.data(forKey: key).map(Self.decode) ?? []
        mirror.records = Dictionary(stored.map { ($0.socketPath, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// An array, or the lone bare record that builds from before the set
    /// stored under the same key.
    private static func decode(_ data: Data) -> [LeoTunnelOrphanRecord] {
        let decoder = JSONDecoder()
        if let records = try? decoder.decode([LeoTunnelOrphanRecord].self, from: data) { return records }
        return (try? decoder.decode(LeoTunnelOrphanRecord.self, from: data)).map { [$0] } ?? []
    }

    /// `~/.leo/state/leoterm/`, where the forwarded socket lived before B-021.
    static let defaultLegacySocketDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".leo/state/leoterm", isDirectory: true)

    /// Stores `record`, replacing any earlier record for the same socket path.
    func record(_ record: LeoTunnelOrphanRecord) {
        mutate { $0[record.socketPath] = record; return true }
    }

    /// Every stored record, ordered by socket path.
    func records() -> [LeoTunnelOrphanRecord] {
        mirror.lock.withLock { Self.ordered(mirror.records) }
    }

    private static func ordered(_ records: [String: LeoTunnelOrphanRecord]) -> [LeoTunnelOrphanRecord] {
        records.values.sorted { $0.socketPath < $1.socketPath }
    }

    /// Removes the stored record only if it still equals `record` -- a concurrent
    /// `record(_:)` call (a newer tunnel on the same socket) may already have
    /// replaced it. Records for other sockets are never touched.
    func clear(matching record: LeoTunnelOrphanRecord) {
        mutate {
            guard $0[record.socketPath] == record else { return false }
            $0[record.socketPath] = nil
            return true
        }
    }

    /// Applies `change` (true if it changed anything) to the mirror under the
    /// lock, then brings `UserDefaults`
    /// in line with it after the lock is released. Two threads may persist
    /// concurrently, so each re-checks the mirror once its write lands and
    /// rewrites if a later change moved it on: whichever write runs last has
    /// by construction seen the final mirror value, so the persisted record
    /// converges on it and a stale write can never clobber a newer record.
    private func mutate(_ change: (inout [String: LeoTunnelOrphanRecord]) -> Bool) {
        let didChange = mirror.lock.withLock { change(&mirror.records) }
        if didChange { persist() }
    }

    private func persist() {
        var written: [String: LeoTunnelOrphanRecord]
        repeat {
            written = mirror.lock.withLock { mirror.records }
            write(written)
        } while mirror.lock.withLock({ mirror.records }) != written
    }

    private func write(_ records: [String: LeoTunnelOrphanRecord]) {
        guard !records.isEmpty, let data = try? JSONEncoder().encode(Self.ordered(records)) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    /// For each stored record whose pid is still running with the same start
    /// time, SIGTERM it, give them all up to 1s (once, not per record) to exit,
    /// then SIGKILL whatever is still around.
    /// A mismatched start time means the pid was recycled by an unrelated
    /// process: it is never signalled and the record is left untouched (there is
    /// nothing safe to reap). A live matching pid is provably a dead run's
    /// orphan only because Leo is single-instance per bundle
    /// (`LeoSingleInstance`, D-051): no other copy sharing these defaults is
    /// running. Pre-B-021 records predate that lock and are only dropped
    /// (`dropLegacy`). `inspector`/`signaller`/`sleep` are injected so
    /// tests can run this synchronously without real processes or real waits.
    func reapAtLaunch(
        inspector: (Int32) -> TimeInterval?,
        signaller: (Int32, Int32) -> Void,
        sleep: (Duration) -> Void = leoTunnelRealSleep
    ) {
        let (legacy, candidates) = records().reduce(into: ([LeoTunnelOrphanRecord](), [LeoTunnelOrphanRecord]())) { result, record in
            if isLegacy(record) { result.0.append(record) } else { result.1.append(record) }
        }
        legacy.forEach(dropLegacy)
        let orphans = candidates.filter { inspector($0.pid) == $0.startTime }
        guard !orphans.isEmpty else { return }
        orphans.forEach { signaller($0.pid, SIGTERM) }
        sleep(.seconds(1))
        orphans.filter { inspector($0.pid) == $0.startTime }.forEach { signaller($0.pid, SIGKILL) }
        // A replacement tunnel may have been recorded while we were signalling;
        // atomically re-check-and-unlink so that race can only ever preserve
        // the replacement, never drop it.
        for record in orphans {
            removeIfStillCurrent(record) { try? fileManager.removeItem(atPath: record.socketPath) }
        }
    }

    private func isLegacy(_ record: LeoTunnelOrphanRecord) -> Bool {
        URL(fileURLWithPath: record.socketPath).deletingLastPathComponent().standardizedFileURL.path
            == legacySocketDirectory.standardizedFileURL.path
    }

    /// A pre-B-021 record: the build that wrote it took no instance lock
    /// (D-051), so it may still be running beside this one and its pid
    /// can't be proven an orphan. It is never signalled (a leftover ssh
    /// from a crashed pre-B-021 run is harmless and stays), the record is
    /// cleared, and the socket goes only if `LeoControlSocket` finds it
    /// ours and dead.
    private func dropLegacy(_ record: LeoTunnelOrphanRecord) {
        removeIfStillCurrent(record) { LeoControlSocket.removeIfStale(record.socketPath) }
    }

    /// Runs `cleanup` and clears the record atomically with the "still the
    /// current record" check, so a replacement recorded meanwhile is preserved
    /// and its socket untouched.
    private func removeIfStillCurrent(_ record: LeoTunnelOrphanRecord, cleanup: () -> Void) {
        let didClear = mirror.lock.withLock {
            guard mirror.records[record.socketPath] == record else { return false }
            cleanup()
            mirror.records[record.socketPath] = nil
            return true
        }
        if didClear { persist() }
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
