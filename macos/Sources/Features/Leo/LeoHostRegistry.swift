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
    /// cached connection (no second forward) when one already exists.
    func store(for host: String) async throws(LeoError) -> LeoAgentStore {
        if var existing = connections[host] {
            existing.refCount += 1
            connections[host] = existing
            return existing.store
        }

        if host == LeoHost.localhostName {
            let store = storeFactory(nil, nil)
            connections[host] = Connection(store: store, forward: nil, refCount: 1)
            return store
        }

        // Remote: stand up the forward, then build a store over the forwarded
        // socket. Propagate failures without leaving a dangling cached entry.
        let forward = forwardManagerFactory(host)
        let socketPath = try await forward.start()
        let store = storeFactory(socketPath, host)
        connections[host] = Connection(store: store, forward: forward, refCount: 1)
        return store
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
