import Foundation
import Testing

@testable import Ghostty

struct LeoObserveTests {
    @Test func activityClientDeliversSmallCompleteFrameImmediately() async throws {
        guard let url = URL(string: "http://127.0.0.1:8370") else { throw LeoDaemonError.transport("Invalid test URL") }
        let client = LeoActivityClient(config: LeoObserveConfig(baseURL: url, token: "token"), transport: SmallFrameTransport())
        let event = try await nextEventWhileStreamStaysOpen(from: await client.events())
        #expect(event == .agentActivity(seq: 1, at: nil, agent: "a", activity: .idle, currentAction: nil))
    }

    @Test func streamReportsLifecycleAndReconnectsAfterFailure() async throws {
        let transport = LifecycleTransport()
        guard let url = URL(string: "http://127.0.0.1:8370") else { throw LeoDaemonError.transport("Invalid test URL") }
        let client = LeoActivityClient(config: LeoObserveConfig(baseURL: url, token: "token"), transport: transport, initialBackoff: 1, maximumBackoff: 1, sleep: { _ in await transport.recordSleep() })
        var iterator = (await client.events()).makeAsyncIterator()
        let connected = await iterator.next()
        #expect(await iterator.next() == .hello(seq: 1, at: nil, version: nil, serverTime: nil))
        let disconnected = await iterator.next()
        #expect([connected, disconnected] == [.connected, .disconnected(reason: "stream failed")])
        await transport.waitForReconnect()
    }

    @Test func parsesSSETranscript() throws {
        var parser = LeoSSEParser()
        let data = try fixture("events.sse")
        let events = parser.feed(data)
        #expect(events.contains(where: { $0.name == "hello" }))
        #expect(events.contains(where: { $0.name == "agent_activity" }))
    }

    @Test func absentWebBlockIsDisabled() {
        #expect(LeoObserveConfigLoader.parseWeb("agent: claude") == nil)
        let config = LeoObserveConfigLoader.parseWeb("web:\n  enabled: true\n  port: 9000\n  bind: 0.0.0.0")
        #expect(config?.enabled == true)
        #expect(config?.port == 9000)
        #expect(config?.bind == "0.0.0.0")
    }

    @Test func webBlockWithoutEnabledIsDisabled() {
        let config = LeoObserveConfigLoader.parseWeb("web:\n  port: 8370")
        #expect(config?.enabled == false)
    }

    @Test func parsesYAMLBooleanEnabledValues() {
        #expect(LeoObserveConfigLoader.parseWeb("web:\n  enabled: no")?.enabled == false)
        #expect(LeoObserveConfigLoader.parseWeb("web:\n  enabled: False")?.enabled == false)
        #expect(LeoObserveConfigLoader.parseWeb("web:\n  enabled: on")?.enabled == true)
        #expect(LeoObserveConfigLoader.parseWeb("web:\n  enabled: garbage")?.enabled == false)
    }

    @Test func ipv6BindUsesBracketedURL() throws {
        let url = try #require(LeoObserveConfigLoader.baseURL(bind: "::1", port: 8370))
        #expect(url.absoluteString == "http://[::1]:8370")
    }

    @Test func streamFetchesSnapshotOnSequenceGap() async throws {
        let transport = EventTransport()
        let config = LeoObserveConfig(baseURL: URL(string: "http://127.0.0.1:8370")!, token: "token")
        let client = LeoActivityClient(config: config, transport: transport, initialBackoff: 1_000_000_000, maximumBackoff: 1_000_000_000)
        let stream = await client.events()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        #expect(await iterator.next() == .hello(seq: 1, at: nil, version: nil, serverTime: nil))
        #expect(await iterator.next() == .agentActivity(seq: 2, at: nil, agent: "a", activity: .working, currentAction: nil))
        #expect(await iterator.next() == .gap(expected: 3, received: 5))
        #expect(await iterator.next() == .snapshot([LeoObservedAgent(name: "a", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil)]))
        #expect(await iterator.next() == .agentActivity(seq: 5, at: nil, agent: "a", activity: .idle, currentAction: nil))
        #expect(await iterator.next() == .agentSpawned(seq: 6, at: nil, agent: LeoAgent(name: "b", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)))
        #expect(await iterator.next() == .agentStateChanged(seq: 7, at: nil, agent: "b", status: .stopped, restarts: 2, wakeOnMessage: true))
        #expect(await iterator.next() == .agentStopped(seq: 8, at: nil, agent: "b", wakeOnMessage: false))
        #expect(await transport.counter.stateFetches == 1)
    }

    @Test func decodesHelloFeatures() {
        let withFeatures = LeoActivityClient.decode(LeoSSEEvent(
            name: "hello", data: #"{"seq":1,"version":1,"boot_id":"b","features":["bridge_turns","dispatch_tree","from_the_future"]}"#, id: nil
        ))
        #expect(withFeatures == .hello(
            seq: 1, at: nil, version: "1", serverTime: nil, bootID: "b",
            features: ["bridge_turns", "dispatch_tree", "from_the_future"]
        ))
        let without = LeoActivityClient.decode(LeoSSEEvent(name: "hello", data: #"{"seq":1,"version":1}"#, id: nil))
        #expect(without == .hello(seq: 1, at: nil, version: "1", serverTime: nil, features: []))
    }

    @Test func decodesDispatchChanged() throws {
        let json = #"{"seq":7,"at":"2026-10-06T12:00:00Z","dispatch":{"id":"d-2","name":"fixer","role":"implement","#
            + #""template":"claude","model":"opus","status":"done","stalled":true,"caller_agent":"alpha","#
            + #""parent_dispatch_id":"d-1","started_at":"2026-10-06T11:59:00Z","ended_at":"2026-10-06T12:00:00Z","#
            + #""tokens_in":10,"tokens_out":20,"cost_usd":0.5}}"#
        let event = LeoActivityClient.decode(LeoSSEEvent(name: "dispatch_changed", data: json, id: nil))
        let expected = LeoDispatch(
            id: "d-2", name: "fixer", role: "implement", template: "claude", model: "opus", status: "done",
            stalled: true, callerAgent: "alpha", parentDispatchID: "d-1",
            startedAt: "2026-10-06T11:59:00Z", endedAt: "2026-10-06T12:00:00Z"
        )
        #expect(event == .dispatchChanged(seq: 7, dispatch: expected))
        #expect(event?.sequence == 7)

        let malformed = LeoActivityClient.decode(LeoSSEEvent(name: "dispatch_changed", data: #"{"seq":8,"dispatch":{"name":"no id"}}"#, id: nil))
        #expect(malformed == .other(seq: 8, type: "dispatch_changed"), "a malformed dispatch still advances the sequence")
        #expect(malformed?.sequence == 8)
    }

    @Test func decodesAgentTurnCompleted() throws {
        let json = #"{"seq":9,"agent":"alpha","session_id":"s1","outcome":"completed","preview":"All \u001b[31mdone\nnow","#
            + #""tokens":{"input":10,"output":20,"cache_read":30,"cache_creation":40},"cost_usd":0.25,"#
            + #""context":{"tokens":1000,"window":200000,"percent":0.5}}"#
        let event = LeoActivityClient.decode(LeoSSEEvent(name: "agent_turn_completed", data: json, id: nil))
        guard case .agentTurnCompleted(let seq, let turn) = event else { Issue.record("not a turn: \(String(describing: event))"); return }
        #expect(seq == 9)
        #expect(turn.agent == "alpha" && turn.sessionID == "s1" && turn.outcome == .completed)
        #expect(!turn.preview.contains("\u{1b}") && !turn.preview.contains("\n"), "agent text is sanitized")
        #expect(turn.tokens == LeoTurnTokens(input: 10, output: 20, cacheRead: 30, cacheCreation: 40))
        #expect(turn.costUSD == 0.25)
        #expect(turn.context == LeoContextUsage(tokens: 1000, window: 200_000, percent: 0.5))

        let bare = LeoActivityClient.decode(LeoSSEEvent(
            name: "agent_turn_completed", data: #"{"seq":10,"agent":"alpha","outcome":"exploded","preview":"x"}"#, id: nil))
        guard case .agentTurnCompleted(_, let minimal) = bare else { Issue.record("not a turn"); return }
        #expect(minimal.outcome == .unknown, "an outcome from the future reads as unknown")
        #expect(minimal.costUSD == nil && minimal.context == nil && minimal.tokens == nil)
    }

    @Test func malformedTurnCompletedIsSequenceOnly() {
        let event = LeoActivityClient.decode(LeoSSEEvent(name: "agent_turn_completed", data: #"{"seq":11,"outcome":"completed"}"#, id: nil))
        #expect(event == .other(seq: 11, type: "agent_turn_completed"))
    }

    @Test func decodesAgentUsageEvent() {
        let json = #"{"seq":12,"agent":"alpha","usage":{"session_id":"s1","session":{"tokens":5,"cost_usd":0.1},"#
            + #""incarnation":{"tokens":9,"cost_usd":0.3},"context":{"tokens":10,"window":100,"percent":10}}}"#
        let event = LeoActivityClient.decode(LeoSSEEvent(name: "agent_usage", data: json, id: nil))
        let expected = LeoAgentUsage(
            sessionID: "s1", session: LeoUsageTotals(tokens: 5, costUSD: 0.1), incarnation: LeoUsageTotals(tokens: 9, costUSD: 0.3),
            context: LeoContextUsage(tokens: 10, window: 100, percent: 10)
        )
        #expect(event == .agentUsage(seq: 12, agent: "alpha", usage: expected))
        let malformed = LeoActivityClient.decode(LeoSSEEvent(name: "agent_usage", data: #"{"seq":13,"agent":"alpha","usage":{"session":"x"}}"#, id: nil))
        #expect(malformed == .other(seq: 13, type: "agent_usage"))
    }

    /// Unconsumed events (turns, dispatches, anything newer) still carry
    /// the daemon's seq: skipping them made the next known event look like
    /// a gap and forced a recovery refetch on every 1 s dispatch tick.
    @Test func unconsumedSeqEventsDoNotOpenGap() async throws {
        let frames = """
        event: hello
        data: {"seq":1,"version":1}

        event: agent_turn_completed
        data: {"seq":2,"agent":"alpha","session_id":"s1","outcome":"completed","preview":"done"}

        event: dispatch_changed
        data: {"seq":3,"dispatch":{"id":"d-1","status":"running","stalled":false,"caller_agent":"alpha","started_at":"2026-10-06T12:00:00Z"}}

        event: agent_activity
        data: {"seq":4,"agent":"alpha","activity":"idle"}

        """ + "\n"
        let httpTransport = OpenFrameTransport(frames: frames)
        let config = LeoObserveConfig(baseURL: URL(string: "http://127.0.0.1:8370")!, token: "token")
        let httpEvents = try await eventsThroughActivity(from: await LeoActivityClient(config: config, transport: httpTransport).events())
        let socketTransport = OpenFrameSocketTransport(frames: frames)
        let socketEvents = try await eventsThroughActivity(from: await LeoSocketActivityClient(transport: socketTransport).events())

        for events in [httpEvents, socketEvents] {
            #expect(!events.contains { if case .gap = $0 { true } else { false } }, "no gap: \(events)")
            #expect(!events.contains { if case .snapshot = $0 { true } else { false } })
            #expect(events.contains { if case .agentTurnCompleted(2, let turn) = $0 { turn.preview == "done" } else { false } })
            #expect(events.contains { if case .dispatchChanged(3, let dispatch) = $0 { dispatch.id == "d-1" } else { false } })
        }
        #expect(await httpTransport.counter.stateFetches == 0)
        #expect(socketTransport.stateFetchCount == 0)
    }

    /// Collects events until seq 4's `agent_activity` arrives (the
    /// transports keep the stream open, so it never ends by itself).
    private func eventsThroughActivity(from stream: AsyncStream<LeoObserveEvent>) async throws -> [LeoObserveEvent] {
        let collector = ObservedEvents()
        let task = Task { for await event in stream { await collector.append(event) } }
        defer { task.cancel() }
        await awaitCondition(message: "seq 4 never arrived") {
            await collector.events.contains { if case .agentActivity(4, _, _, _, _, _) = $0 { true } else { false } }
        }
        return await collector.events
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
    }

    /// "Immediately" means without waiting for more bytes or EOF: the
    /// transports that use this never finish their stream, so a client that
    /// buffered a complete frame would never deliver it at all. The deadline
    /// only turns that hang into a failure; it is not a latency budget (a
    /// 50 ms one flaked under suite load).
    private func nextEventWhileStreamStaysOpen(from stream: AsyncStream<LeoObserveEvent>) async throws -> LeoObserveEvent? {
        let result = NextEvent()
        let task = Task {
            var iterator = stream.makeAsyncIterator()
            await result.set(await iterator.next())
        }
        defer { task.cancel() }
        await awaitCondition(message: "Event was not delivered while the stream stayed open") { await result.isSet }
        return await result.value
    }
}

private struct EventTransport: LeoActivityTransport {
    let counter = EventCounter()

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        await counter.increment()
        return (Data(#"{"ok":true,"data":{"agents":[{"name":"a","status":"running","activity":"idle"}]}}"#.utf8), 200)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(("""
            event: hello
            data: {"seq":1}

            event: agent_activity
            data: {"seq":2,"agent":"a","activity":"working"}

            event: agent_activity
            data: {"seq":5,"agent":"a","activity":"idle"}

            event: agent_spawned
            data: {"seq":6,"agent":{"name":"b","status":"running"}}

            event: agent_state_changed
            data: {"seq":7,"agent":"b","status":"stopped","restarts":2,"wake_on_message":true}

            event: agent_stopped
            data: {"seq":8,"agent":"b","wake_on_message":false}

            """ + "\n").utf8))
            continuation.finish()
        }
    }
}

private struct SmallFrameTransport: LeoActivityTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 200) }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("event: agent_activity\ndata: {\"seq\":1,\"agent\":\"a\",\"activity\":\"idle\"}\n\n".utf8))
        }
    }
}

private final class LifecycleTransport: LeoActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0

    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections }

    func fetch(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 200) }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        connections += 1
        let current = connections
        lock.unlock()
        if current == 1 {
            return AsyncThrowingStream { continuation in
                continuation.yield(Data("event: hello\ndata: {\"seq\":1}\n\n".utf8))
                continuation.finish(throwing: LeoDaemonError.transport("stream failed"))
            }
        }
        return AsyncThrowingStream { _ in }
    }

    func recordSleep() {}

    func waitForReconnect() async {
        await awaitCondition(message: "Stream did not reconnect") { self.connectionCount >= 2 }
    }
}

private actor NextEvent {
    private var storedValue: LeoObserveEvent??
    var isSet: Bool { storedValue != nil }
    var value: LeoObserveEvent? { storedValue ?? nil }
    func set(_ value: LeoObserveEvent?) { storedValue = value }
}

private actor EventCounter {
    private(set) var stateFetches = 0
    func increment() { stateFetches += 1 }
}

private actor ObservedEvents {
    private(set) var events: [LeoObserveEvent] = []
    func append(_ event: LeoObserveEvent) { events.append(event) }
}

/// Yields `frames` once and keeps the stream open; counts `/state` fetches.
private struct OpenFrameTransport: LeoActivityTransport {
    let frames: String
    let counter = EventCounter()

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        await counter.increment()
        return (Data(#"{"ok":true,"data":{"agents":[]}}"#.utf8), 200)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let frames = frames
        return AsyncThrowingStream { continuation in continuation.yield(Data(frames.utf8)) }
    }
}

/// The socket client's equivalent of `OpenFrameTransport`.
private final class OpenFrameSocketTransport: LeoSocketActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0
    private let frames: String

    init(frames: String) { self.frames = frames }

    var stateFetchCount: Int { lock.withLock { fetches } }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        lock.withLock { fetches += 1 }
        return .init(status: 200, body: Data(#"{"ok":true,"data":{"agents":[]}}"#.utf8))
    }

    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        let frames = frames
        return AsyncThrowingStream { continuation in continuation.yield(Data(frames.utf8)) }
    }
}
