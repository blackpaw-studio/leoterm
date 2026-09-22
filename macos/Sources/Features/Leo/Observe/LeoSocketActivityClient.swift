import Foundation
import OSLog

private let leoSocketActivityLogger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

/// Streaming transport for a `.socketEvents`-flavor daemon (leo >= 0.29):
/// `GET /events` (unix-socket SSE) and `GET /state`, both unprefixed since a
/// socket now always addresses exactly one host.
protocol LeoSocketActivityTransport: LeoDaemonTransport {
    func stream(path: String, socketPath: String, idleTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error>
}

extension LeoUnixSocketTransport: LeoSocketActivityTransport {}

/// Reads agent activity from a single daemon socket via `GET /events`
/// (SSE: `hello`, `agent_*` events, `: ping` keep-alives -- ignored by
/// `LeoSSEParser`) and `GET /state` (enveloped or bare JSON). Reuses
/// `LeoActivityClient.decode` for wire decoding since the event payloads are
/// identical to the legacy TCP observability API; the only difference is
/// transport (unix socket, unprefixed paths, no bearer token).
actor LeoSocketActivityClient {
    private let socketPath: String
    private let transport: any LeoSocketActivityTransport
    private let initialBackoff: UInt64
    private let maximumBackoff: UInt64
    private let sleeper: @Sendable (UInt64) async throws -> Void

    init(socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
         transport: any LeoSocketActivityTransport = LeoUnixSocketTransport(),
         initialBackoff: UInt64 = 1_000_000_000,
         maximumBackoff: UInt64 = 30_000_000_000,
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.socketPath = socketPath
        self.transport = transport
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        sleeper = sleep
    }

    func fetchState() async throws -> [LeoObservedAgent] {
        struct State: Decodable, Sendable { let agents: [LeoObservedAgent] }
        let response = try await transport.send(.init(method: "GET", path: "/state"), socketPath: socketPath, timeout: 5)
        guard (200..<300).contains(response.status) else {
            throw LeoDaemonError.transport("State endpoint returned HTTP \(response.status)")
        }
        return try LeoDaemonEnvelope<State>.decode(response.body).value().agents
    }

    func events() -> AsyncStream<LeoObserveEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<LeoObserveEvent>.Continuation) async {
        var backoff = initialBackoff
        var lastSequence: Int?
        while !Task.isCancelled {
            var parser = LeoSSEParser()
            var reason = "EOF"
            leoSocketActivityLogger.log("socketActivity: connecting socketPath=\(self.socketPath, privacy: .public)")
            do {
                for try await bytes in transport.stream(path: "/events", socketPath: socketPath, idleTimeout: 60) {
                    for raw in parser.feed(bytes) {
                        guard let event = LeoActivityClient.decode(raw) else { continue }
                        let sequence = event.sequence
                        if sequence >= 0, let lastSequence, sequence > lastSequence + 1 {
                            continuation.yield(.gap(expected: lastSequence + 1, received: sequence))
                            if let agents = try? await fetchState() { continuation.yield(.snapshot(agents)) }
                        }
                        if sequence >= 0 { lastSequence = sequence }
                        if case .hello(let seq, let at, let version, let serverTime, _) = event {
                            backoff = initialBackoff
                            leoSocketActivityLogger.log("socketActivity: hello seq=\(seq) version=\(version ?? "nil", privacy: .public) serverTime=\(serverTime ?? "nil", privacy: .public) at=\(at ?? "nil", privacy: .public)")
                        }
                        continuation.yield(event)
                    }
                }
            } catch is CancellationError { break
            } catch {
                reason = Self.reason(for: error)
            }
            guard !Task.isCancelled else { break }
            leoSocketActivityLogger.log("socketActivity: disconnected reason=\(reason, privacy: .public)")
            continuation.yield(.disconnected(reason: reason))
            leoSocketActivityLogger.log("socketActivity: reconnecting backoffNanoseconds=\(backoff)")
            do { try await sleeper(backoff) } catch { return }
            backoff = min(backoff * 2, maximumBackoff)
        }
        continuation.finish()
    }

    private static func reason(for error: Error) -> String {
        guard let error = error as? LeoDaemonError else { return String(describing: error) }
        if case .transport(let reason) = error { return reason }
        return String(describing: error)
    }
}
