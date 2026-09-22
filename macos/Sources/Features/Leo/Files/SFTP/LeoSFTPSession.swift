import Foundation

/// Owns the one SFTP connection an accessor uses, opening it lazily. After
/// the connection ends (tunnel dropped, server exited, `close()`), the next
/// operation launches a fresh one: at most one attempt per operation, never
/// in the background, so there is no reconnect loop to run away.
actor LeoSFTPSession {
    private let launcher: any LeoSFTPLaunching
    private var connecting: Task<LeoSFTPClient, Error>?
    /// The live transport, kept outside the task so `deinit` can stop it.
    private var transport: LeoSFTPTransport?

    init(launcher: any LeoSFTPLaunching) {
        self.launcher = launcher
    }

    deinit {
        transport?.close()
    }

    func client() async throws -> LeoSFTPClient {
        while true {
            if let current = connecting {
                if let client = try? await current.value, !client.transport.isClosed { return client }
                // Another caller may have started a replacement while this
                // one was suspended; join it instead of launching a second.
                guard connecting == current else { continue }
            }
            let task = Task { [launcher] in try await Self.connect(using: launcher) }
            connecting = task
            let client = try await task.value
            if connecting == task { transport = client.transport }
            return client
        }
    }

    func close() async {
        guard let current = connecting else { return }
        connecting = nil
        transport = nil
        (try? await current.value)?.transport.close()
    }

    private static func connect(using launcher: any LeoSFTPLaunching) async throws -> LeoSFTPClient {
        let channel: LeoSFTPChannel
        do {
            channel = try launcher.launch()
        } catch {
            throw LeoFileAccessError.disconnected
        }
        let transport = LeoSFTPTransport(channel: channel)
        do {
            let server = try await transport.handshake()
            guard server.version == LeoSFTPCodec.protocolVersion else {
                throw LeoFileAccessError.protocolError("server speaks SFTP v\(server.version), not v\(LeoSFTPCodec.protocolVersion)")
            }
            return LeoSFTPClient(transport: transport, server: server)
        } catch {
            transport.close()
            throw error
        }
    }
}
