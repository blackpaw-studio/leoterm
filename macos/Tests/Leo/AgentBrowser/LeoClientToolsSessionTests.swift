import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A scriptable client-tools daemon: each `events()` is a new stream the
/// test feeds; routes record their calls.
@MainActor final class FakeClientTools: LeoClientToolsProviding {
    private(set) var streams: [AsyncStream<LeoClientToolsEvent>.Continuation] = []
    private(set) var endedStreams = 0
    private(set) var registered: [(group: String, tools: [LeoClientToolDefinition])] = []
    private(set) var claims: [String] = []
    private(set) var results: [(id: String, outcome: LeoClientToolOutcome)] = []
    var claimErrors: [String: any Error] = [:]
    var pendingRequests: [LeoClientToolPending] = []

    func events() async -> AsyncStream<LeoClientToolsEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LeoClientToolsEvent.self)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.endedStreams += 1 } }
        streams.append(continuation)
        return stream
    }

    func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int {
        registered.append((group, tools))
        return registered.count
    }

    func claim(_ requestID: String) async throws -> LeoClientToolRequest {
        claims.append(requestID)
        if let error = claimErrors[requestID] { throw error }
        guard let request = pendingRequests.first(where: { $0.request.id == requestID })?.request else {
            throw LeoClientToolsError.unknownRequest(message: "unknown")
        }
        return request
    }

    func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws {
        results.append((requestID, outcome))
    }

    func pending() async throws -> [LeoClientToolPending] { pendingRequests }

    /// Sends `event` on the newest stream.
    func send(_ event: LeoClientToolsEvent) { streams.last?.yield(event) }

    /// The newest stream ends, as when the daemon drops it.
    func drop(reason: String = "closed") {
        streams.last?.yield(.disconnected(reason: reason))
        streams.last?.finish()
    }
}

/// Runs requests until the test finishes them; records cancellations.
@MainActor final class FakeToolsExecutor: LeoClientToolsExecuting {
    private(set) var started: [String] = []
    private(set) var cancelled: [String] = []
    private var waiting: [String: CheckedContinuation<LeoClientToolOutcome, Never>] = [:]

    func execute(_ request: LeoClientToolRequest, on host: LeoHostID) async -> LeoClientToolOutcome {
        started.append(request.id)
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting[id] = $0 }
        } onCancel: {
            Task { @MainActor in
                self.cancelled.append(id)
                self.waiting.removeValue(forKey: id)?.resume(returning: .failure(LeoClientToolError(code: "cancelled", message: "")))
            }
        }
    }

    func finish(_ id: String, _ outcome: LeoClientToolOutcome = .success([.text("ok")])) {
        waiting.removeValue(forKey: id)?.resume(returning: outcome)
    }
}

/// C6: one machine's provider stream. It registers the browser group on
/// every hello, claims and runs requests, recovers pending ones without
/// running an in-flight one twice, and opens no stream when it shouldn't.
@MainActor
struct LeoClientToolsSessionTests {
    private let client = FakeClientTools()
    private let executor = FakeToolsExecutor()

    private func session(platformSupported: Bool = true) -> LeoClientToolsSession {
        LeoClientToolsSession(
            host: .remote("dionysus"), client: client, executor: executor,
            isPlatformSupported: platformSupported, sleep: { _ in }
        )
    }

    private static func request(_ id: String, tool: String = "browser_click") -> LeoClientToolRequest {
        LeoClientToolRequest(id: id, agent: "alpha", group: "browser", tool: tool, args: .object(["ref": .string("s1e1")]), timeoutSeconds: 30)
    }

    /// Lets the session's tasks run until `condition` holds, without a clock.
    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    private func connected(_ session: LeoClientToolsSession) async {
        session.setAdvertised(true)
        session.start()
        await until { client.streams.count == 1 }
        client.send(.hello(clientID: "ct_1"))
        await until { client.registered.count == 1 }
    }

    @Test func registersTheBrowserGroupOncePerHello() async {
        let session = session()
        defer { session.stop() }
        await connected(session)

        #expect(client.registered.first?.group == "browser")
        #expect(client.registered.first?.tools == LeoBrowserTools.definitions)

        client.drop()
        await until { client.streams.count == 2 }
        client.send(.hello(clientID: "ct_2"))
        await until { client.registered.count == 2 }
        #expect(client.registered.count == 2)
    }

    @Test func aRequestIsClaimedRunAndAnswered() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: "")]

        client.send(.request(Self.request("ctr_1")))
        await until { executor.started == ["ctr_1"] }
        executor.finish("ctr_1")
        await until { client.results.count == 1 }

        #expect(client.claims == ["ctr_1"])
        #expect(client.results.first?.id == "ctr_1")
        #expect(client.results.first?.outcome == .success([.text("ok")]))
    }

    @Test func turningTheSettingOffClosesTheStreamAndAbortsWhatRuns() async {
        let session = session()
        await connected(session)
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: "")]
        client.send(.request(Self.request("ctr_1")))
        await until { executor.started == ["ctr_1"] }

        session.setEnabled(false)

        await until { client.endedStreams == 1 }
        await until { executor.cancelled == ["ctr_1"] }
        #expect(client.results.isEmpty)
        #expect(client.streams.count == 1)

        session.setEnabled(true)
        await until { client.streams.count == 2 }
        session.stop()
    }

    @Test func pendingRecoveryDoesNotRerunAnInFlightClick() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: "")]
        client.send(.request(Self.request("ctr_1")))
        await until { executor.started == ["ctr_1"] }

        // A gap: the daemon still lists it, claimed by this stream.
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: "ct_1")]
        client.send(.gap(expected: 4, received: 6))
        // The stream drops: the daemon releases it, and the next stream re-claims it.
        client.drop()
        await until { client.streams.count == 2 }
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: "")]
        client.send(.hello(clientID: "ct_2"))
        await until { client.claims.count == 2 }

        executor.finish("ctr_1")
        await until { client.results.count == 1 }
        #expect(executor.started == ["ctr_1"])
        #expect(client.claims == ["ctr_1", "ctr_1"])
        #expect(client.results.map(\.id) == ["ctr_1"])
    }

    @Test func aRequestFinishedWhileDisconnectedIsAnsweredAfterTheReclaim() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: "")]
        client.send(.request(Self.request("ctr_1")))
        await until { executor.started == ["ctr_1"] }

        client.drop()
        await until { client.streams.count == 2 }
        executor.finish("ctr_1")
        for _ in 0..<50 { await Task.yield() }
        #expect(client.results.isEmpty)

        client.send(.hello(clientID: "ct_2"))
        await until { client.results.count == 1 }
        #expect(executor.started == ["ctr_1"])
    }

    @Test func aClaimConflictIsIgnored() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        client.claimErrors["ctr_1"] = LeoClientToolsError.alreadyClaimed(message: "taken")
        client.pendingRequests = [
            LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: ""),
            LeoClientToolPending(request: Self.request("ctr_2"), claimedBy: ""),
        ]

        client.send(.request(Self.request("ctr_1")))
        client.send(.request(Self.request("ctr_2")))
        await until { executor.started == ["ctr_2"] }

        #expect(client.claims == ["ctr_1", "ctr_2"])
        executor.finish("ctr_2")
        await until { client.results.count == 1 }
        #expect(client.results.map(\.id) == ["ctr_2"])
    }

    @Test func aCancelledRequestIsAbortedAndNotAnswered() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1", tool: "browser_handoff"), claimedBy: "")]
        client.send(.request(Self.request("ctr_1", tool: "browser_handoff")))
        await until { executor.started == ["ctr_1"] }

        client.send(.cancelled(LeoClientToolCancellation(id: "ctr_1", agent: "alpha", reason: "timeout")))

        await until { executor.cancelled == ["ctr_1"] }
        for _ in 0..<50 { await Task.yield() }
        #expect(client.results.isEmpty)
    }

    @Test func noStreamWithoutTheFeatureOrBeforeMacOS14() async {
        let unadvertised = session()
        unadvertised.start()
        let old = session(platformSupported: false)
        old.setAdvertised(true)
        old.start()

        for _ in 0..<50 { await Task.yield() }

        #expect(client.streams.isEmpty)
        unadvertised.stop()
        old.stop()
    }

    @Test func aDaemonWithoutClientToolsIsNotRetried() async {
        let session = session()
        defer { session.stop() }
        session.setAdvertised(true)
        session.start()
        await until { client.streams.count == 1 }

        client.drop(reason: LeoClientToolsClient.unsupportedReason)
        for _ in 0..<50 { await Task.yield() }

        #expect(client.streams.count == 1)
    }
}
