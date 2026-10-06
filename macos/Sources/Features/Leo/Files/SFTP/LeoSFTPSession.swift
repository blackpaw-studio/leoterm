import Foundation

/// Owns the one SFTP connection an accessor uses, opening it lazily. After
/// the connection ends (tunnel dropped, server exited), the next operation
/// launches a fresh one: at most one attempt per operation, never in the
/// background, so there is no reconnect loop to run away. `close()` is
/// final: it ends the connection at once, even mid-handshake, fails what's
/// in flight as `.closed`, and nothing launches again.
actor LeoSFTPSession {
    nonisolated let launcher: any LeoSFTPLaunching
    private var connecting: Task<LeoSFTPClient, Error>?
    /// The latest transport, from its launch on (before its handshake), so
    /// `close()` and `deinit` can stop it without waiting for the server.
    private var transport: LeoSFTPTransport?
    private var isClosed = false

    init(launcher: any LeoSFTPLaunching) {
        self.launcher = launcher
    }

    deinit {
        transport?.close()
    }

    func client() async throws -> LeoSFTPClient {
        while true {
            guard !isClosed else { throw LeoFileAccessError.closed }
            if let current = connecting {
                if let client = try? await current.value, !client.transport.isClosed { return client }
                // Another caller may have started a replacement (or closed
                // the session) while this one was suspended.
                guard connecting == current else { continue }
            }
            let (transport, channel) = try Self.launch(using: launcher)
            self.transport = transport
            let task = Task { try await Self.handshake(on: transport, channel: channel) }
            connecting = task
            let client = try await task.value
            guard !isClosed else { throw LeoFileAccessError.closed }
            return client
        }
    }

    func close() {
        isClosed = true
        connecting = nil
        transport?.close(with: .closed)
        transport = nil
    }

    private static func launch(using launcher: any LeoSFTPLaunching) throws -> (LeoSFTPTransport, LeoSFTPChannel) {
        do {
            let channel = try launcher.launch()
            return (LeoSFTPTransport(channel: channel), channel)
        } catch let error as LeoFileAccessError {
            throw error
        } catch {
            throw LeoFileAccessError.disconnected
        }
    }

    private static func handshake(on transport: LeoSFTPTransport, channel: LeoSFTPChannel) async throws -> LeoSFTPClient {
        do {
            let server = try await transport.handshake()
            guard server.version == LeoSFTPCodec.protocolVersion else {
                throw LeoFileAccessError.protocolError("server speaks SFTP v\(server.version), not v\(LeoSFTPCodec.protocolVersion)")
            }
            return LeoSFTPClient(transport: transport, server: server)
        } catch LeoFileAccessError.disconnected {
            let startupFailure = channel.startupFailure()
            transport.close()
            throw startupFailure ?? LeoFileAccessError.disconnected
        } catch {
            transport.close()
            throw error
        }
    }
}
