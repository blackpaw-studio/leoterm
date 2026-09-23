import Foundation

/// The transport for a remote host's daemon, reached through the tunnel's
/// forwarded socket. That socket can vanish under a running tunnel (the OS
/// may purge the cache directory it lives in), and nothing brings it back
/// but a new tunnel -- so a missing socket reads as "reconnect", not as a
/// path the user can do nothing about.
struct LeoTunnelSocketTransport: LeoSocketActivityTransport {
    static let vanishedMessage = "the connection’s tunnel socket is gone. Reconnect to restore it"

    let base: any LeoSocketActivityTransport

    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        do {
            return try await base.send(request, socketPath: socketPath, timeout: timeout)
        } catch {
            throw Self.map(error)
        }
    }

    func stream(path: String, socketPath: String, idleTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        let upstream = base.stream(path: path, socketPath: socketPath, idleTimeout: idleTimeout)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func map(_ error: Error) -> Error {
        guard case LeoDaemonError.socketMissing = error else { return error }
        return LeoDaemonError.hostUnavailable(vanishedMessage)
    }
}
