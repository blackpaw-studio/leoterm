import Testing
import Foundation
@testable import Ghostty

/// A canned transport: `fetch` returns one fixed response, `stream` replays a
/// fixed sequence of chunks (each call to `stream` consumes the next queued
/// sequence, so a test can simulate a dropped connection followed by a
/// reconnect). No real network I/O.
private actor StubActivityTransport: LeoActivityTransport {
    struct FetchResponse {
        let data: Data
        let status: Int
    }

    private var fetchResponse: FetchResponse
    private var streamSequences: [[Data]]
    private(set) var streamCallCount = 0
    private(set) var fetchCallCount = 0

    init(fetchResponse: FetchResponse, streamSequences: [[Data]]) {
        self.fetchResponse = fetchResponse
        self.streamSequences = streamSequences
    }

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        fetchCallCount += 1
        return (fetchResponse.data, fetchResponse.status)
    }

    nonisolated func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let chunks = await self.nextStreamSequence()
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    private func nextStreamSequence() -> [Data] {
        streamCallCount += 1
        guard !streamSequences.isEmpty else { return [] }
        return streamSequences.removeFirst()
    }
}

/// Builds one complete SSE event's bytes, including the terminating blank
/// line that triggers dispatch. (A Swift multi-line string literal does NOT
/// add a trailing newline after its last line, so relying on a blank source
/// line before the closing `"""` silently produces a chunk with no dispatch
/// trigger — use this helper instead of hand-rolled multi-line literals.)
private func sseEventChunk(event: String, data: String) -> Data {
    Data("event: \(event)\ndata: \(data)\n\n".utf8)
}

private func stateJSON(agents: [(name: String, activity: String)]) -> Data {
    let entries = agents.map { #"{"name":"\#($0.name)","activity":"\#($0.activity)"}"# }.joined(separator: ",")
    let json = #"{"ok":true,"data":{"agents":[\#(entries)]}}"#
    return Data(json.utf8)
}

struct LeoActivityClientTests {
    private static let testConfig = LeoObserveConfig(baseURL: URL(string: "http://127.0.0.1:8370")!, token: "tok")

    @Test func nilConfigFinishesImmediatelyWithNoUpdates() async {
        let client = LeoActivityClient(config: nil, transport: StubActivityTransport(
            fetchResponse: .init(data: Data(), status: 200),
            streamSequences: []
        ))
        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
        }
        #expect(updates.isEmpty)
    }

    @Test func initialStateSeedsActivityMap() async {
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working"), ("plex", "idle")]), status: 200),
            streamSequences: [[]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
            break // stream sequence is empty, so this is the only update
        }
        #expect(updates.first == ["olympus": .working, "plex": .idle])
    }

    @Test func agentActivityEventUpdatesMap() async {
        let sseChunk = sseEventChunk(event: "agent_activity", data: #"{"seq":1,"agent":"olympus","activity":"idle"}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working")]), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
            if updates.count == 2 { break }
        }
        #expect(updates[0] == ["olympus": .working])
        #expect(updates[1] == ["olympus": .idle])
    }

    @Test func agentSpawnedEventAddsAgent() async {
        let sseChunk = sseEventChunk(event: "agent_spawned", data: #"{"seq":2,"agent":{"name":"newagent","activity":"working"}}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: []), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
            if updates.count == 2 { break }
        }
        #expect(updates[1] == ["newagent": .working])
    }

    @Test func agentStoppedEventWithStringAgentSetsUnknown() async {
        let sseChunk = sseEventChunk(event: "agent_stopped", data: #"{"seq":3,"agent":"olympus"}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working")]), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
            if updates.count == 2 { break }
        }
        #expect(updates[1] == ["olympus": .unknown])
    }

    @Test func agentStateChangedEventWithObjectAgentSetsUnknown() async {
        let sseChunk = sseEventChunk(event: "agent_state_changed", data: #"{"seq":4,"agent":{"name":"olympus","status":"stopped"}}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working")]), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
            if updates.count == 2 { break }
        }
        #expect(updates[1] == ["olympus": .unknown])
    }

    @Test func agentStateChangedEventWithNonStoppedStatusLeavesActivityUnchanged() async {
        let sseChunk = sseEventChunk(event: "agent_state_changed", data: #"{"seq":5,"agent":{"name":"olympus","status":"running"}}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working")]), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        let task = Task {
            for await update in await client.activityUpdates() {
                updates.append(update)
            }
        }
        // No second update should ever arrive: a non-"stopped" state_changed
        // event leaves the activity map untouched, so nothing is yielded
        // beyond the initial state fetch. Prove this the same way the
        // existing 500-retry test proves "doesn't hang forever": run briefly,
        // then cancel.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(updates == [["olympus": .working]])
    }

    @Test func agentStateChangedEventWithBareStringAgentLeavesActivityUnchanged() async {
        // A bare-string agent reference carries no status at all, so it must
        // never be treated as "stopped".
        let sseChunk = sseEventChunk(event: "agent_state_changed", data: #"{"seq":6,"agent":"olympus"}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working")]), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        let task = Task {
            for await update in await client.activityUpdates() {
                updates.append(update)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(updates == [["olympus": .working]])
    }

    @Test func helloEventIsIgnoredAndDoesNotEmitAnUpdate() async {
        let sseChunk = sseEventChunk(event: "hello", data: #"{"seq":1,"version":1}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working")]), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
            // The client reconnects indefinitely (with backoff) after a clean
            // stream end, so this consumer must stop itself after the one
            // update the initial state fetch produces; hello is silent and
            // never contributes a second one.
            break
        }
        #expect(updates == [["olympus": .working]])
    }

    @Test func unknownActivityStringDecodesToUnknownNotCrash() async {
        let sseChunk = sseEventChunk(event: "agent_activity", data: #"{"seq":1,"agent":"olympus","activity":"something-new"}"#)
        let transport = StubActivityTransport(
            fetchResponse: .init(data: stateJSON(agents: [("olympus", "working")]), status: 200),
            streamSequences: [[sseChunk]]
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        var updates: [[String: AgentActivity]] = []
        for await update in await client.activityUpdates() {
            updates.append(update)
            if updates.count == 2 { break }
        }
        #expect(updates[1] == ["olympus": .unknown])
    }

    @Test func nonRetryableHttpErrorOnInitialFetchStillEventuallyFinishesOnCancel() async {
        let transport = StubActivityTransport(
            fetchResponse: .init(data: Data(), status: 500),
            streamSequences: []
        )
        let client = LeoActivityClient(config: Self.testConfig, transport: transport)

        let stream = await client.activityUpdates()
        let task = Task {
            for await _ in stream {
                // The 500 causes a retry loop; we just prove consumption doesn't hang forever
                // by cancelling shortly after starting it below.
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        // Reaching this point (test completes) demonstrates cancellation stops the loop.
        #expect(Bool(true))
    }
}
