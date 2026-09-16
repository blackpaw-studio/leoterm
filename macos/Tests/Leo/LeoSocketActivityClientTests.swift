import Foundation
import Testing

@testable import Ghostty

/// `LeoSocketActivityClient` reads `/events` (SSE: hello, agent_* events,
/// `: ping` keep-alives) and `/state` from a single daemon socket -- no host
/// tagging, since a socket now always addresses exactly one host.
struct LeoSocketActivityClientTests {
    @Test func stateAcceptsBareAndEnvelopedResponses() async throws {
        let bare = StaticTransport(stateBody: Data(#"{"agents":[{"name":"bare"}]}"#.utf8))
        #expect(try await LeoSocketActivityClient(transport: bare).fetchState().map(\.name) == ["bare"])

        let enveloped = StaticTransport(stateBody: Data(#"{"ok":true,"data":{"agents":[{"name":"wrapped"}]}}"#.utf8))
        #expect(try await LeoSocketActivityClient(transport: enveloped).fetchState().map(\.name) == ["wrapped"])
    }

    @Test func streamDecodesHelloAndAgentEventsAndIgnoresPingComments() async throws {
        let transport = SingleShotTransport(frames: """
        : ping

        event: hello
        data: {"seq":1,"version":"0.29.0"}

        event: agent_spawned
        data: {"seq":2,"agent":{"name":"alpha"}}

        """ + "\n")
        let collector = EventCollector()
        let stream = await LeoSocketActivityClient(transport: transport).events()
        let task = Task { for await event in stream { await collector.append(event) } }
        await awaitCondition { await collector.count >= 2 }
        task.cancel()
        let events = await collector.events
        #expect(events.first == .hello(seq: 1, at: nil, version: "0.29.0", serverTime: nil))
        #expect(events.contains { if case .agentSpawned(_, _, let agent) = $0 { agent.name == "alpha" } else { false } })
    }

    @Test func sequenceGapFetchesStateSnapshot() async throws {
        let transport = GapTransport()
        let collector = EventCollector()
        let stream = await LeoSocketActivityClient(transport: transport, sleep: { _ in throw CancellationError() }).events()
        let task = Task { for await event in stream { await collector.append(event) } }

        await awaitCondition {
            let events = await collector.events
            return events.contains(.gap(expected: 2, received: 3)) &&
                events.contains(.snapshot([.init(name: "recovered", status: nil, activity: nil, currentAction: nil, lastActivityAt: nil)]))
        }
        #expect(transport.stateFetchCount == 1)
        task.cancel()
    }

    @Test func closedStreamDisconnectsThenReconnectsAfterInjectedBackoff() async throws {
        let transport = ReconnectingTransport()
        let backoff = BackoffClock()
        let client = LeoSocketActivityClient(transport: transport, initialBackoff: 7, sleep: { try await backoff.sleep($0) })
        let collector = EventCollector()
        let stream = await client.events()
        let task = Task { for await event in stream { await collector.append(event) } }

        await awaitCondition { await collector.events.contains(.disconnected(reason: "EOF")) }
        #expect(transport.streamCount == 1)
        #expect(await backoff.delays == [7])
        await backoff.advance()
        await awaitCondition { transport.streamCount == 2 }

        task.cancel()
    }

    @Test func cancellingStreamStopsWithoutHanging() async throws {
        let transport = ReconnectingTransport()
        let stream = await LeoSocketActivityClient(transport: transport).events()
        let task = Task { for await _ in stream {} }
        await awaitCondition { transport.streamCount >= 1 }
        task.cancel()
        for _ in 0..<25 { await Task.yield() }
    }
}

private actor EventCollector {
    private(set) var events: [LeoObserveEvent] = []
    var count: Int { events.count }
    func append(_ event: LeoObserveEvent) { events.append(event) }
}

private struct StaticTransport: LeoSocketActivityTransport {
    let stateBody: Data
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        .init(status: 200, body: stateBody)
    }
    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct SingleShotTransport: LeoSocketActivityTransport {
    let frames: String
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        .init(status: 200, body: Data(#"{"agents":[]}"#.utf8))
    }
    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(frames.utf8))
        }
    }
}

private actor BackoffClock {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var delays: [UInt64] = []

    func sleep(_ delay: UInt64) async throws {
        delays.append(delay)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func advance() { continuation?.resume(); continuation = nil }
}

private final class ReconnectingTransport: LeoSocketActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var streamCount: Int { lock.withLock { count } }

    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        .init(status: 200, body: Data(#"{"agents":[]}"#.utf8))
    }

    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        let attempt = lock.withLock { count += 1; return count }
        return AsyncThrowingStream { continuation in
            if attempt == 1 { continuation.finish() }
        }
    }
}

private final class GapTransport: LeoSocketActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var fetchCount = 0
    var stateFetchCount: Int { lock.withLock { fetchCount } }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        lock.withLock { fetchCount += 1 }
        return .init(status: 200, body: Data(#"{"agents":[{"name":"recovered"}]}"#.utf8))
    }

    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("event: hello\ndata: {\"seq\":1}\n\nevent: agent_stopped\ndata: {\"seq\":3,\"agent\":\"a\"}\n\n".utf8))
        }
    }
}
