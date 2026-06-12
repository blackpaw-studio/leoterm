import Foundation
import os

/// App-owned registry mapping a leo host **name** to a cached connection so the
/// sidebar can retarget per board. Each connection holds a `LeoAgentStore` and,
/// for remote hosts, a running `LeoForwardManager`.
///
/// Connections are **reference-counted**: multiple boards on the same host share
/// one forward + store. The last `release` tears the forward down.
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
        let store: LeoAgentStore
        /// The forward backing a remote host; `nil` for localhost.
        let forward: LeoForwardManager?
        var refCount: Int
    }

    private let forwardManagerFactory: ForwardManagerFactory
    private let storeFactory: StoreFactory
    private var connections: [String: Connection] = [:]
    /// In-flight acquisitions, keyed by host. Created synchronously before the
    /// first `await` so concurrent callers for the same NEW host coalesce onto
    /// one forward+store instead of racing to create two.
    private var inFlight: [String: Task<LeoAgentStore, any Error>] = [:]
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

    /// Acquire the store for `host`, incrementing its reference count. Reuses a
    /// cached connection (no second forward) when one already exists, and
    /// coalesces concurrent acquisitions of the same NEW host onto a single
    /// in-flight forward+store so `N` concurrent callers yield `refCount == N`.
    func store(for host: String) async throws(LeoError) -> LeoAgentStore {
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

        do {
            // Awaiting the shared task installs the `Connection` (refCount 0)
            // exactly once; every caller then claims one hold below.
            _ = try await task.value
        } catch let error as LeoError {
            throw error
        } catch {
            throw LeoError.daemonUnreachable
        }

        guard var connection = connections[host] else {
            // The task removed `inFlight` on failure but left no connection;
            // surface a generic transport error rather than crash.
            throw LeoError.daemonUnreachable
        }
        connection.refCount += 1
        connections[host] = connection
        return connection.store
    }

    /// Build and register an in-flight acquisition `Task` for `host`. The task
    /// stands up the forward (remote) or builds the store directly (localhost),
    /// installs a `Connection` with `refCount == 0`, and clears its `inFlight`
    /// slot. Callers claim their hold after awaiting it. On failure it removes
    /// the `inFlight` entry so no dangling state remains.
    private func makeAcquireTask(for host: String) -> Task<LeoAgentStore, any Error> {
        let task = Task<LeoAgentStore, any Error> { @MainActor in
            do {
                let connection = try await self.buildConnection(for: host)
                self.connections[host] = connection
                self.inFlight[host] = nil
                return connection.store
            } catch {
                self.inFlight[host] = nil
                throw error
            }
        }
        inFlight[host] = task
        return task
    }

    /// Build a fresh `Connection` (refCount 0) for `host`. Localhost gets a
    /// default-socket store with no forward; a remote stands up the forward and
    /// builds a store over the forwarded socket.
    private func buildConnection(for host: String) async throws -> Connection {
        if host == LeoHost.localhostName {
            let store = storeFactory(nil, nil)
            return Connection(store: store, forward: nil, refCount: 0)
        }
        let forward = forwardManagerFactory(host)
        let socketPath = try await forward.start()
        let store = storeFactory(socketPath, host)
        return Connection(store: store, forward: forward, refCount: 0)
    }

    /// Release one hold on `host`. At refcount zero the cached connection is
    /// dropped and a remote host's forward is torn down.
    func release(_ host: String) {
        guard var connection = connections[host] else {
            Self.logger.warning("release of untracked host \(host, privacy: .public)")
            return
        }
        connection.refCount -= 1
        if connection.refCount > 0 {
            connections[host] = connection
            return
        }
        connections.removeValue(forKey: host)
        if let forward = connection.forward {
            Task { await forward.stop() }
        }
    }
}
