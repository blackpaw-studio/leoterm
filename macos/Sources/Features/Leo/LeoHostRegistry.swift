import Foundation
import os

/// App-owned registry mapping a leo host **name** to a cached connection so the
/// sidebar can retarget per board. Each connection holds a `LeoAgentStore` and,
/// for remote hosts, a running `LeoForwardManager`.
///
/// Connections are **reference-counted**: multiple boards on the same host share
/// one forward + store. The last `release` tears the forward down. Connections
/// are also **versioned**: a forward that dies is invalidated, and the holds
/// outstanding against that dead generation are drained separately so a late
/// release can never decrement the replacement connection.
///
/// The forward-manager and store factories are injected so the registry is
/// unit-testable without spawning a real `ssh`/`leo`.
@MainActor
final class LeoHostRegistry {
    /// Builds a `LeoForwardManager` for a remote host. Defaults to the real
    /// process launcher.
    typealias ForwardManagerFactory = @Sendable (_ host: String) -> LeoForwardManager
    /// Builds a `LeoAgentStore` over a socket client. `socketPath`/`host` are
    /// `nil` for localhost (default socket, host-less CLI).
    typealias StoreFactory = @MainActor (_ socketPath: String?, _ host: String?) -> LeoAgentStore

    /// One cached host connection plus its reference count.
    private struct Connection {
        /// Monotonic id distinguishing this connection from a replacement built
        /// after it was invalidated.
        let generation: UInt64
        let store: LeoAgentStore
        /// The forward backing a remote host; `nil` for localhost.
        let forward: LeoForwardManager?
        var refCount: Int
    }

    /// An invalidated connection's outstanding holds. Releases from those
    /// holders are absorbed here instead of decrementing the live connection.
    private struct Orphan {
        let generation: UInt64
        var outstanding: Int
    }

    private let forwardManagerFactory: ForwardManagerFactory
    private let storeFactory: StoreFactory
    private var connections: [String: Connection] = [:]
    /// In-flight acquisitions, keyed by host. Created synchronously before the
    /// first `await` so concurrent callers for the same NEW host coalesce onto
    /// one forward+store instead of racing to create two.
    private var inFlight: [String: Task<LeoAgentStore, any Error>] = [:]
    /// The connection generation each in-flight acquisition will install.
    private var inFlightGeneration: [String: UInt64] = [:]
    /// How many callers are awaiting each connection generation. A connection
    /// that lands with zero refs AND zero waiters (every caller was cancelled)
    /// must be torn down rather than leaked.
    private var waiters: [UInt64: Int] = [:]
    /// Releases that arrived while an acquisition was still in flight, keyed by
    /// the generation they were meant for. Applied once every waiter has had a
    /// chance to claim its hold.
    private var pendingReleases: [UInt64: Int] = [:]
    /// Outstanding holds against invalidated connections, oldest first.
    private var orphans: [String: [Orphan]] = [:]
    private var nextGeneration: UInt64 = 0
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-host-registry")

    init(
        forwardManagerFactory: @escaping ForwardManagerFactory = { host in LeoForwardManager(host: host) },
        storeFactory: @escaping StoreFactory = { socketPath, host in
            let socket = socketPath ?? NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath
            return LeoAgentStore(daemon: LeoSocketClient(socketPath: socket, host: host))
        }
    ) {
        self.forwardManagerFactory = forwardManagerFactory
        self.storeFactory = storeFactory
    }

    /// Whether `host` currently has a live cached connection. Owners poll this
    /// to notice a forward that died underneath them (the registry drops the
    /// connection) and re-acquire.
    func hasConnection(_ host: String) -> Bool { connections[host] != nil }

    /// Acquire the store for `host`, incrementing its reference count. Reuses a
    /// cached connection (no second forward) when one already exists, and
    /// coalesces concurrent acquisitions of the same NEW host onto a single
    /// in-flight forward+store so `N` concurrent callers yield `refCount == N`.
    ///
    /// Throws `LeoError` when the connection can't be established, or
    /// `CancellationError` when the calling task was cancelled while awaiting —
    /// in which case no hold is claimed and the freshly-built connection is
    /// reconciled away rather than leaking a live forward.
    func store(for host: String) async throws -> LeoAgentStore {
        // Fast path: a fully-established connection already exists.
        if var existing = connections[host] {
            existing.refCount += 1
            connections[host] = existing
            return existing.store
        }

        // Coalesce: reuse an in-flight acquisition if one is already running,
        // otherwise start one synchronously (before any `await`) so a racing
        // caller observes it.
        let task = inFlight[host] ?? makeAcquireTask(for: host)
        guard let generation = inFlightGeneration[host] else { throw LeoError.daemonUnreachable }
        waiters[generation, default: 0] += 1

        // Awaiting the shared task installs the `Connection` (refCount 0)
        // exactly once; every caller then claims one hold below.
        let failure: (any Error)? = await Self.failure(awaiting: task)

        // Claim a hold, unless the acquire failed or this caller was cancelled
        // while suspended (awaiting a `Task`'s value is not itself cancellable,
        // so the check has to happen here).
        let isCancelled = Task.isCancelled
        let claimed = failure == nil && !isCancelled ? claimHold(on: host, generation: generation) : nil
        dropWaiter(generation)
        reconcile(host)

        if let claimed { return claimed }
        if let failure { throw failure }
        throw isCancelled ? CancellationError() : LeoError.daemonUnreachable
    }

    /// Release one hold on `host`. Holds against a connection that was already
    /// invalidated (its forward died) are absorbed without touching the live
    /// replacement. At refcount zero the cached connection is dropped and a
    /// remote host's forward is torn down. A release that arrives while the
    /// acquisition is still in flight is recorded and applied when it lands.
    func release(_ host: String) {
        if releaseOrphan(host) { return }
        if var connection = connections[host] {
            connection.refCount = max(0, connection.refCount - 1)
            connections[host] = connection
            reconcile(host)
            return
        }
        if let generation = inFlightGeneration[host] {
            pendingReleases[generation, default: 0] += 1
            return
        }
        Self.logger.warning("release of untracked host \(host, privacy: .public)")
    }

    // MARK: - Internals

    /// Await `task`, returning the error it threw (or the caller's cancellation)
    /// and `nil` on success.
    private static func failure(awaiting task: Task<LeoAgentStore, any Error>) async -> (any Error)? {
        do {
            _ = try await task.value
            return nil
        } catch {
            return error
        }
    }

    private func claimHold(on host: String, generation: UInt64) -> LeoAgentStore? {
        // The connection we waited for may already have been invalidated and
        // replaced; a hold on it would be a hold on a dead forward.
        guard var connection = connections[host], connection.generation == generation else { return nil }
        connection.refCount += 1
        connections[host] = connection
        return connection.store
    }

    private func dropWaiter(_ generation: UInt64) {
        guard let count = waiters[generation] else { return }
        if count <= 1 { waiters[generation] = nil } else { waiters[generation] = count - 1 }
    }

    /// Absorb a release belonging to an invalidated connection. Oldest orphan
    /// first: holders of dead generations always predate holders of the live
    /// one. Returns whether the release was consumed.
    private func releaseOrphan(_ host: String) -> Bool {
        guard var pending = orphans[host], !pending.isEmpty else { return false }
        pending[0].outstanding -= 1
        if pending[0].outstanding <= 0 { pending.removeFirst() }
        orphans[host] = pending.isEmpty ? nil : pending
        Self.logger.debug("absorbed stale release for \(host, privacy: .public)")
        return true
    }

    /// Apply any deferred releases and tear the connection down once nothing
    /// holds it and nobody is still waiting to claim it.
    private func reconcile(_ host: String) {
        guard var connection = connections[host] else { return }
        let generation = connection.generation
        // Waiters have yet to claim their holds; deferred releases are applied
        // only once they have, so the refcount never dips below zero.
        guard (waiters[generation] ?? 0) == 0 else { return }
        if let pending = pendingReleases.removeValue(forKey: generation) {
            connection.refCount = max(0, connection.refCount - pending)
        }
        if connection.refCount > 0 {
            connections[host] = connection
            return
        }
        connections.removeValue(forKey: host)
        teardown(connection)
    }

    private func teardown(_ connection: Connection) {
        guard let forward = connection.forward else { return }
        Task { await forward.stop() }
    }

    /// Drop the cached connection for a host whose forward died on its own. The
    /// forward is already gone, so there is nothing to stop; the next acquire
    /// rebuilds both forward and store. Outstanding holds are remembered so the
    /// eventual releases don't decrement the replacement.
    private func invalidate(_ host: String, generation: UInt64) {
        guard let dead = connections[host], dead.generation == generation else { return }
        connections.removeValue(forKey: host)
        pendingReleases[generation] = nil
        if dead.refCount > 0 {
            orphans[host, default: []].append(Orphan(generation: generation, outstanding: dead.refCount))
        }
        Self.logger.warning("dropping connection for \(host, privacy: .public): forward died")
    }

    /// Build and register an in-flight acquisition `Task` for `host`. The task
    /// stands up the forward (remote) or builds the store directly (localhost),
    /// installs a `Connection` with `refCount == 0`, and clears its `inFlight`
    /// slot. Callers claim their hold after awaiting it. On failure it removes
    /// the `inFlight` entry so no dangling state remains.
    private func makeAcquireTask(for host: String) -> Task<LeoAgentStore, any Error> {
        nextGeneration &+= 1
        let generation = nextGeneration
        let task = Task<LeoAgentStore, any Error> { @MainActor in
            do {
                let connection = try await self.buildConnection(for: host, generation: generation)
                self.connections[host] = connection
                self.clearInFlight(host, generation: generation)
                // Every waiter may already have been cancelled; don't leave a
                // live forward behind with nobody holding it.
                self.reconcile(host)
                return connection.store
            } catch {
                self.clearInFlight(host, generation: generation)
                self.pendingReleases[generation] = nil
                throw error
            }
        }
        inFlight[host] = task
        inFlightGeneration[host] = generation
        return task
    }

    private func clearInFlight(_ host: String, generation: UInt64) {
        guard inFlightGeneration[host] == generation else { return }
        inFlight[host] = nil
        inFlightGeneration[host] = nil
    }

    /// Build a fresh `Connection` (refCount 0) for `host`. Localhost gets a
    /// default-socket store with no forward; a remote stands up the forward and
    /// builds a store over the forwarded socket.
    private func buildConnection(for host: String, generation: UInt64) async throws -> Connection {
        if host == LeoHost.localhostName {
            let store = storeFactory(nil, nil)
            return Connection(generation: generation, store: store, forward: nil, refCount: 0)
        }
        let forward = forwardManagerFactory(host)
        await forward.setTerminationHandler { [weak self] host in
            Task { @MainActor in self?.invalidate(host, generation: generation) }
        }
        let socketPath = try await forward.start()
        let store = storeFactory(socketPath, host)
        return Connection(generation: generation, store: store, forward: forward, refCount: 0)
    }
}
