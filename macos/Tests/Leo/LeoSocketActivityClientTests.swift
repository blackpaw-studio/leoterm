import Foundation
import Testing

@testable import Ghostty

/// `LeoSocketActivityClient` reads `/events` (SSE: hello, agent_* events,
/// `: ping` keep-alives) and `/state` from a single daemon socket -- no host
/// tagging, since a socket now always addresses exactly one host.
struct LeoSocketActivityClientTests {
    @Test func stateReturnsAgentsFromEnvelopedResponse() async throws {
        let transport = RecordingTransport(stateBody: Data(#"{"ok":true,"data":{"agents":[{"name":"wrapped"}]}}"#.utf8))
        #expect(try await LeoSocketActivityClient(transport: transport).fetchState().map(\.name) == ["wrapped"])
        #expect(transport.paths == ["/state"])
    }

    @Test func stateRejectsABareUnenvelopedResponse() async throws {
        let transport = RecordingTransport(stateBody: Data(#"{"agents":[{"name":"bare"}]}"#.utf8))
        await #expect(throws: (any Error).self) {
            _ = try await LeoSocketActivityClient(transport: transport).fetchState()
        }
    }

    @Test func stateThrowsOnNon2xxStatusInsteadOfDecoding() async throws {
        let transport = RecordingTransport(
            stateBody: Data(#"{"ok":true,"data":{"agents":[{"name":"should-not-appear"}]}}"#.utf8),
            stateStatus: 500
        )
        await #expect(throws: LeoDaemonError.transport("State endpoint returned HTTP 500")) {
            _ = try await LeoSocketActivityClient(transport: transport).fetchState()
        }
    }

    @Test func stateThrowsDaemonErrorFromAnOkFalseEnvelope() async throws {
        let transport = RecordingTransport(stateBody: Data(#"{"ok":false,"error":"offline","code":"host_unavailable"}"#.utf8))
        await #expect(throws: LeoDaemonError.daemon(code: "host_unavailable", message: "offline", matches: [])) {
            _ = try await LeoSocketActivityClient(transport: transport).fetchState()
        }
    }

    @Test func streamDecodesHelloAndAgentEventsAndIgnoresPingCommentsOnTheUnprefixedPath() async throws {
        let transport = RecordingTransport(frames: """
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
        #expect(events.contains { if case .agentSpawned(_, _, let agent, _) = $0 { agent.name == "alpha" } else { false } })
        #expect(transport.streamRequests.map(\.path) == ["/events"])
        #expect(transport.streamRequests.map(\.idleTimeout) == [60])
    }

    /// Ground truth captured directly from a running leo 0.30.1 daemon
    /// (`curl --unix-socket ~/.leo/state/leo.sock http://leo/events`), trimmed
    /// to one sample per event kind. The real daemon sends `hello.version`
    /// as a JSON *number* (`1`), not the hand-written string fixture above
    /// (`"0.29.0"`) -- that mismatch let a decode bug ship: `LeoActivityClient
    /// .decode`'s `Payload.version: String?` threw on the numeric value and
    /// `try?` silently swallowed it, dropping every hello event in
    /// production while the (wrong) test fixture kept passing.
    @Test func decodesEveryEventKindFromARealDaemonCapture() throws {
        var parser = LeoSSEParser()
        let events = parser.feed(try fixture("events-real-daemon.sse"))
            .compactMap { LeoActivityClient.decode($0) }

        guard case .hello(let seq, _, let version, let serverTime, _) = events.first else {
            Issue.record("expected hello first, got \(events.first as Any)")
            return
        }
        #expect(seq == 1438)
        #expect(version == "1")
        #expect(serverTime == "2026-09-21T11:39:55.043926-04:00")

        #expect(events.contains {
            if case .agentStateChanged(_, _, let agent, let status, _, _) = $0 { agent == "brand" && status == .stopped } else { false }
        })
        #expect(events.contains {
            if case .agentStopped(_, _, let agent, _) = $0 { agent == "brand" } else { false }
        })
        #expect(events.contains {
            if case .agentSpawned(_, _, let agent, _) = $0 { agent.name == "brand" } else { false }
        })
        #expect(events.contains {
            if case .agentActivity(_, _, let agent, let activity, _, _) = $0 { agent == "brand" && activity == .working } else { false }
        })
    }

    @Test func sequenceGapFetchesStateSnapshot() async throws {
        let transport = GapTransport()
        let collector = EventCollector()
        let stream = await LeoSocketActivityClient(transport: transport).events()
        let task = Task { for await event in stream { await collector.append(event) } }

        await awaitCondition {
            let events = await collector.events
            return events.contains(.gap(expected: 2, received: 3)) &&
                events.contains(.snapshot([.init(name: "recovered", status: nil, activity: nil, currentAction: nil, lastActivityAt: nil)]))
        }
        #expect(transport.stateFetchCount == 1)
        task.cancel()
    }

    /// Principle 5 (D-048/D-061): a dropped stream reports `.disconnected`
    /// once and ends -- no backoff timer, no second connection. Recovery is
    /// the user's Retry, which opens a fresh stream.
    @Test func closedStreamDisconnectsOnceAndNeverReconnects() async throws {
        let transport = ReconnectingTransport()
        let stream = await LeoSocketActivityClient(transport: transport).events()

        var events: [LeoObserveEvent] = []
        for await event in stream { events.append(event) }

        #expect(events == [.disconnected(reason: "Connection closed")])
        #expect(transport.streamCount == 1)
    }

    @Test func aStreamThatFailsReportsItsReasonAndEnds() async throws {
        let transport = FailingStreamTransport()
        let stream = await LeoSocketActivityClient(transport: transport).events()

        var events: [LeoObserveEvent] = []
        for await event in stream { events.append(event) }

        #expect(events == [.disconnected(reason: "Connection refused")])
        #expect(transport.streamCount == 1)
    }

    @Test func cancellingStreamClosesTheUnderlyingTransportStream() async throws {
        let transport = RecordingTransport(frames: "")
        let stream = await LeoSocketActivityClient(transport: transport).events()
        let task = Task { for await _ in stream {} }
        await awaitCondition { transport.streamRequests.count >= 1 }
        task.cancel()
        await awaitCondition(message: "transport never observed stream cancellation") { transport.cancellations >= 1 }
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
    }
}

private actor EventCollector {
    private(set) var events: [LeoObserveEvent] = []
    var count: Int { events.count }
    func append(_ event: LeoObserveEvent) { events.append(event) }
}

/// Records every `/state` fetch and `/events` stream request (path,
/// idle timeout) and whether the stream was cancelled by its consumer --
/// catches accidental misroutes or leaked streams.
private final class RecordingTransport: LeoSocketActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentPaths: [String] = []
    private var streams: [(path: String, idleTimeout: TimeInterval)] = []
    private var cancelledCount = 0
    private let stateBody: Data
    private let stateStatus: Int
    private let frames: String

    init(stateBody: Data = Data(#"{"ok":true,"data":{"agents":[]}}"#.utf8), stateStatus: Int = 200, frames: String = "") {
        self.stateBody = stateBody
        self.stateStatus = stateStatus
        self.frames = frames
    }

    var paths: [String] { lock.withLock { sentPaths } }
    var streamRequests: [(path: String, idleTimeout: TimeInterval)] { lock.withLock { streams } }
    var cancellations: Int { lock.withLock { cancelledCount } }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        lock.withLock { sentPaths.append(request.path) }
        return .init(status: stateStatus, body: stateBody)
    }

    func stream(path: String, socketPath _: String, idleTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { streams.append((path, idleTimeout)) }
        let frames = frames
        return AsyncThrowingStream { continuation in
            if !frames.isEmpty { continuation.yield(Data(frames.utf8)) }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.cancelledCount += 1 } }
        }
    }
}

private final class ReconnectingTransport: LeoSocketActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var streamCount: Int { lock.withLock { count } }

    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        .init(status: 200, body: Data(#"{"ok":true,"data":{"agents":[]}}"#.utf8))
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
        return .init(status: 200, body: Data(#"{"ok":true,"data":{"agents":[{"name":"recovered"}]}}"#.utf8))
    }

    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("event: hello\ndata: {\"seq\":1}\n\nevent: agent_stopped\ndata: {\"seq\":3,\"agent\":\"a\"}\n\n".utf8))
        }
    }
}

private final class FailingStreamTransport: LeoSocketActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var streamCount: Int { lock.withLock { count } }

    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        .init(status: 200, body: Data(#"{"ok":true,"data":{"agents":[]}}"#.utf8))
    }

    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { $0.finish(throwing: LeoDaemonError.transport("Connection refused")) }
    }
}
