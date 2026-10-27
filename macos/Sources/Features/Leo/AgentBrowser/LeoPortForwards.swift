import Foundation

/// One machine's port forwards for agent browsers: refcounted per browser,
/// opened over the machine's ControlMaster when it has one and one ssh
/// process each otherwise. Create one per connection; `releaseAll()` when the
/// machine disconnects (forwards die with the master or process anyway, this
/// drops the bookkeeping). The local machine's planner never forwards, so the
/// manager is a pass-through there.
@MainActor
final class LeoPortForwards {
    /// Opens that fail `.portBusy` are retried on a new local port this many
    /// times, so a port taken between the probe and ssh's bind costs nothing.
    private static let maxAttempts = 4

    private struct Forward {
        let local: Int
        var browsers: Set<String>
    }

    /// An open in progress. `browsers` are everyone waiting on it; a release
    /// removes a browser from here, and an open that finishes with nobody
    /// left closes itself. `id` lets a finishing open tell its own entry from
    /// a later one for the same port.
    private struct Pending {
        let id: Int
        var browsers: Set<String>
        var task: Task<Int, Error>?
    }

    private let planner: LeoPortForwardPlanner
    private let runner: any LeoPortForwardRunning
    /// Remote port → forward.
    private var forwards: [Int: Forward] = [:]
    /// Remote port → open in progress.
    private var pending: [Int: Pending] = [:]
    private var nextPendingID = 0
    /// Local ports claimed by opens that haven't finished.
    private var reservedLocals: Set<Int> = []
    /// Local ports of forwards that left state but whose close hasn't
    /// finished; a new forward must not reuse one while its cancel is in flight.
    private var closingLocals: Set<Int> = []
    /// Bumped by `releaseAll()` so an open that finishes afterwards cleans up
    /// after itself.
    private var epoch = 0

    /// `controlPath` non-nil → `makeMux(controlPath)`, else `makeProcess()`.
    init(
        planner: LeoPortForwardPlanner,
        controlPath: String?,
        makeMux: (String) -> any LeoPortForwardRunning,
        makeProcess: () -> any LeoPortForwardRunning
    ) {
        self.planner = planner
        runner = controlPath.map(makeMux) ?? makeProcess()
    }

    /// Ensures a forward for `url`'s remote port exists and holds it for
    /// `browser`. Returns the URL to load; `url` itself when it needs no
    /// forward. Throws `CancellationError` when `browser` was released (or
    /// the machine disconnected) before the forward came up.
    func acquire(_ url: URL, browser: String) async throws -> URL {
        guard let remote = planner.remotePort(for: url) else { return url }
        try await hold(remote: remote, browser: browser)
        guard forwards[remote]?.browsers.contains(browser) == true else { throw CancellationError() }
        return toLocal(url)
    }

    /// Remote-terms URL → the URL the web view loads, for forwards that
    /// exist. Anything else is returned as given.
    func toLocal(_ url: URL) -> URL {
        planner.toLocal(url, using: forwards.mapValues(\.local))
    }

    /// The web view's URL → remote terms, for forwards that exist.
    func toRemote(_ url: URL) -> URL {
        planner.toRemote(url, using: Dictionary(uniqueKeysWithValues: forwards.map { ($0.value.local, $0.key) }))
    }

    /// Drops `browser`'s hold, including on opens still in progress; forwards
    /// nobody else holds are cancelled. Every orphan leaves state before the
    /// first close is awaited, so a concurrent acquire never joins a forward
    /// that is about to be torn down.
    func release(browser: String) async {
        for remote in pending.keys {
            pending[remote]?.browsers.remove(browser)
        }
        var orphans: [(remote: Int, local: Int)] = []
        for (remote, forward) in forwards {
            var remaining = forward.browsers
            remaining.remove(browser)
            if remaining.isEmpty {
                orphans.append((remote, forward.local))
                forwards.removeValue(forKey: remote)
            } else {
                forwards[remote] = Forward(local: forward.local, browsers: remaining)
            }
        }
        await close(orphans)
    }

    /// Machine disconnected (or app quitting): cancel everything. The
    /// closes run off the main actor, so a quit that blocks the main thread
    /// can wait on the returned task.
    @discardableResult
    func releaseAll() -> Task<Void, Never> {
        epoch += 1
        let closing = forwards.map { (remote: $0.key, local: $0.value.local) }
        forwards = [:]
        pending = [:]
        let runner = runner
        return Task.detached {
            for (remote, local) in closing {
                await runner.close(local: local, remotePort: remote)
            }
        }
    }

    private func close(_ closing: [(remote: Int, local: Int)]) async {
        closingLocals.formUnion(closing.map(\.local))
        for (remote, local) in closing {
            await runner.close(local: local, remotePort: remote)
            closingLocals.remove(local)
        }
    }

    // MARK: - Opening

    private func hold(remote: Int, browser: String) async throws {
        var owners: Set<String> = [browser]
        var dead: Int?
        if let existing = forwards[remote] {
            if runner.isOpen(local: existing.local) {
                forwards[remote]?.browsers.insert(browser)
                return
            }
            // The forward's process died: replace it, keeping everyone who held it.
            forwards.removeValue(forKey: remote)
            owners.formUnion(existing.browsers)
            dead = existing.local
        }
        if pending[remote] != nil {
            pending[remote]?.browsers.formUnion(owners)
        } else {
            nextPendingID += 1
            let id = nextPendingID
            pending[remote] = Pending(id: id, browsers: owners, task: nil)
            pending[remote]?.task = Task { try await self.openForward(remote: remote, id: id, replacing: dead) }
        }
        guard let task = pending[remote]?.task else { return }
        _ = try await task.value
    }

    private func openForward(remote: Int, id: Int, replacing dead: Int?) async throws -> Int {
        do {
            return try await attemptOpen(remote: remote, id: id, replacing: dead)
        } catch {
            if pending[remote]?.id == id { pending.removeValue(forKey: remote) }
            throw error
        }
    }

    private func attemptOpen(remote: Int, id: Int, replacing dead: Int?) async throws -> Int {
        let startEpoch = epoch
        if let dead { await runner.close(local: dead, remotePort: remote) }
        var busy: Set<Int> = []
        for _ in 0..<Self.maxAttempts {
            let taken = Set(forwards.values.map(\.local)).union(reservedLocals).union(closingLocals).union(busy)
            let local = try planner.localPort(forRemote: remote, avoiding: taken)
            reservedLocals.insert(local)
            defer { reservedLocals.remove(local) }
            do {
                try await runner.open(local: local, remotePort: remote)
            } catch LeoPortForwardError.portBusy {
                busy.insert(local)
                continue
            }
            // Back on the main actor with no suspension until the install, so
            // the owners checked here are the owners installed.
            guard epoch == startEpoch, let entry = pending[remote], entry.id == id, !entry.browsers.isEmpty else {
                if pending[remote]?.id == id { pending.removeValue(forKey: remote) }
                await close([(remote, local)])
                throw CancellationError()
            }
            forwards[remote] = Forward(local: local, browsers: entry.browsers)
            pending.removeValue(forKey: remote)
            return local
        }
        throw LeoPortForwardError.portBusy
    }
}
