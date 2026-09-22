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
