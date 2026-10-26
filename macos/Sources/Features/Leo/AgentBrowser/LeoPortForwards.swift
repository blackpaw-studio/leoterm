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

    private let planner: LeoPortForwardPlanner
    private let runner: any LeoPortForwardRunning
    /// Remote port → forward.
    private var forwards: [Int: Forward] = [:]
    private var inFlight: [Int: Task<Int, Error>] = [:]
    /// Local ports claimed by opens that haven't finished.
    private var reservedLocals: Set<Int> = []
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
    /// forward.
    func acquire(_ url: URL, browser: String) async throws -> URL {
        guard let remote = planner.remotePort(for: url) else { return url }
        _ = try await ensureForward(remote: remote)
        forwards[remote]?.browsers.insert(browser)
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

    /// Drops `browser`'s hold; forwards nobody else holds are cancelled.
    func release(browser: String) async {
        let orphaned = forwards.filter { $0.value.browsers == [browser] }
        for remote in forwards.keys {
            forwards[remote]?.browsers.remove(browser)
        }
        for (remote, forward) in orphaned {
            forwards.removeValue(forKey: remote)
            await runner.close(local: forward.local, remotePort: remote)
        }
    }

    /// Machine disconnected (or app quitting): cancel everything.
    func releaseAll() async {
        epoch += 1
        let closing = forwards
        forwards = [:]
        for (remote, forward) in closing {
            await runner.close(local: forward.local, remotePort: remote)
        }
    }

    // MARK: - Opening

    private func ensureForward(remote: Int) async throws -> Int {
        if let existing = forwards[remote] {
            if runner.isOpen(local: existing.local) { return existing.local }
            forwards.removeValue(forKey: remote)
        }
        if let pending = inFlight[remote] { return try await pending.value }
        let task = Task { try await self.openForward(remote: remote) }
        inFlight[remote] = task
        defer { inFlight.removeValue(forKey: remote) }
        return try await task.value
    }

    private func openForward(remote: Int) async throws -> Int {
        let startEpoch = epoch
        var busy: Set<Int> = []
        for _ in 0..<Self.maxAttempts {
            let taken = Set(forwards.values.map(\.local)).union(reservedLocals).union(busy)
            let local = try planner.localPort(forRemote: remote, avoiding: taken)
            reservedLocals.insert(local)
            defer { reservedLocals.remove(local) }
            do {
                try await runner.open(local: local, remotePort: remote)
            } catch LeoPortForwardError.portBusy {
                busy.insert(local)
                continue
            }
            guard epoch == startEpoch else {
                await runner.close(local: local, remotePort: remote)
                throw CancellationError()
            }
            forwards[remote] = Forward(local: local, browsers: [])
            return local
        }
        throw LeoPortForwardError.portBusy
    }
}
