import Foundation

/// Owns the one SFTP connection an accessor uses, opening it lazily. After
/// the connection ends (tunnel dropped, server exited), the next operation
/// launches a fresh one: at most one attempt per operation, never in the
/// background, so there is no reconnect loop to run away. `close()` is
/// final: it ends the connection at once, even mid-handshake, fails what's
/// in flight as `.closed`, and nothing launches again.
actor LeoSFTPSession {
    nonisolated let launcher: any LeoSFTPLaunching
    /// No-op in production; lets process tests hold a completed handshake
    /// until its EOF is observed, making the generation race deterministic.
    private let beforeAcceptingClient: @Sendable (LeoSFTPClient) async -> Void
    private var connecting: Task<LeoSFTPClient, Error>?
    /// Owns whichever of the subsystem/fallback transports is current, so
    /// close wins even while child-exit classification is in flight.
    private var attempt: LeoSFTPConnectionAttempt?
    private var connectionGeneration: UInt64 = 0
    private var isClosed = false

    init(
        launcher: any LeoSFTPLaunching,
        beforeAcceptingClient: @escaping @Sendable (LeoSFTPClient) async -> Void = { _ in }
    ) {
        self.launcher = launcher
        self.beforeAcceptingClient = beforeAcceptingClient
    }

    deinit {
        attempt?.close()
    }

    func client() async throws -> LeoSFTPClient {
        let startingGeneration = connectionGeneration
        let maximumGeneration = startingGeneration &+ 1
        while true {
            guard !isClosed else { throw LeoFileAccessError.closed }
            if let current = connecting {
                do {
                    let client = try await current.value
                    await beforeAcceptingClient(client)
                    guard !isClosed else { throw LeoFileAccessError.closed }
                    if !client.transport.isClosed { return client }
                    if connecting == current {
                        connecting = nil
                        attempt = nil
                    } else if connecting != nil {
                        // A peer already installed the one replacement this
                        // operation may join.
                        continue
                    }
                    guard connectionGeneration < maximumGeneration else {
                        throw LeoFileAccessError.disconnected
                    }
                    // This operation has not launched its one fresh attempt.
                    continue
                } catch {
                    if connecting == current {
                        connecting = nil
                        attempt = nil
                    }
                    guard !isClosed else { throw LeoFileAccessError.closed }
                    // Every caller already waiting on this attempt observes
                    // the same failure. Only a later operation starts anew.
                    throw error
                }
            }
            guard !isClosed else { throw LeoFileAccessError.closed }
            let attempt = LeoSFTPConnectionAttempt(launcher: launcher)
            self.attempt = attempt
            let task = Task { try await attempt.connect() }
            connectionGeneration &+= 1
            connecting = task
            do {
                let client = try await task.value
                await beforeAcceptingClient(client)
                guard !isClosed else { throw LeoFileAccessError.closed }
                if !client.transport.isClosed { return client }
                if connecting == task {
                    connecting = nil
                    self.attempt = nil
                } else if connecting != nil {
                    continue
                }
                guard connectionGeneration < maximumGeneration else {
                    throw LeoFileAccessError.disconnected
                }
                continue
            } catch {
                if connecting == task {
                    connecting = nil
                    self.attempt = nil
                }
                guard !isClosed else { throw LeoFileAccessError.closed }
                throw error
            }
        }
    }

    func close() {
        isClosed = true
        connecting = nil
        attempt?.close()
        attempt = nil
    }
}

/// One user-triggered connection attempt. It starts the subsystem once and,
/// only after a proven subsystem rejection, starts the fixed bootstrap once.
/// Its lock linearizes child launch with close; no process starts after close.
private final class LeoSFTPConnectionAttempt: @unchecked Sendable {
    private let launcher: any LeoSFTPLaunching
    private let lock = NSLock()
    private var transport: LeoSFTPTransport?
    private var isClosed = false

    init(launcher: any LeoSFTPLaunching) {
        self.launcher = launcher
    }

    func connect() async throws -> LeoSFTPClient {
        let primary = try launch { try launcher.launch() }
        do {
            return try await Self.handshake(on: primary.transport)
        } catch {
            if let fallback = try launchFallback(after: primary.channel) {
                return try await Self.handshake(on: fallback.transport)
            }
            throw error
        }
    }

    func close() {
        let current = lock.withLock {
            isClosed = true
            defer { transport = nil }
            return transport
        }
        current?.close(with: .closed)
    }

    private struct Connection {
        let channel: LeoSFTPChannel
        let transport: LeoSFTPTransport
    }

    /// Holds the lock across the synchronous process launch, making close
    /// and launch a single ordered decision.
    private func launch(_ makeChannel: () throws -> LeoSFTPChannel) throws -> Connection {
        try lock.withLock {
            guard !isClosed else { throw LeoFileAccessError.closed }
            let channel: LeoSFTPChannel
            do {
                channel = try makeChannel()
            } catch let error as LeoFileAccessError {
                throw error
            } catch {
                throw LeoFileAccessError.disconnected
            }
            let next = LeoSFTPTransport(channel: channel)
            transport = next
            return Connection(channel: channel, transport: next)
        }
    }

    private func launchFallback(after channel: LeoSFTPChannel) throws -> Connection? {
        try lock.withLock {
            guard !isClosed else { throw LeoFileAccessError.closed }
            guard let fallback = try launcher.launchFallback(after: channel) else { return nil }
            let next = LeoSFTPTransport(channel: fallback)
            transport = next
            return Connection(channel: fallback, transport: next)
        }
    }

    private static func handshake(on transport: LeoSFTPTransport) async throws -> LeoSFTPClient {
        let server = try await transport.handshake()
        guard server.version == LeoSFTPCodec.protocolVersion else {
            transport.close()
            throw LeoFileAccessError.protocolError("server speaks SFTP v\(server.version), not v\(LeoSFTPCodec.protocolVersion)")
        }
        return LeoSFTPClient(transport: transport, server: server)
    }
}
