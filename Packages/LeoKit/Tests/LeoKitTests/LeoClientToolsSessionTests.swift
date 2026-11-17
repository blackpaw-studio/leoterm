import Foundation
import Testing

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

    /// Streams not yet terminated, updated the moment one ends.
    private let openStreams = LockedCount()
    /// For each landed result, whether a stream was still open when it was posted.
    private(set) var postedWhileOpen: [Bool] = []

    @MainActor func events() async -> AsyncStream<LeoClientToolsEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LeoClientToolsEvent.self)
        openStreams.add(1)
        continuation.onTermination = { [weak self, openStreams] _ in
            openStreams.add(-1)
            Task { @MainActor in self?.endedStreams += 1 }
        }
        streams.append(continuation)
        return stream
    }

    @MainActor func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int {
        registered.append((group, tools))
        return registered.count
    }

    @MainActor func claim(_ requestID: String) async throws -> LeoClientToolRequest {
        claims.append(requestID)
        if let error = claimErrors[requestID] { throw error }
        guard let request = pendingRequests.first(where: { $0.request.id == requestID })?.request else {
            throw LeoClientToolsError.unknownRequest(message: "unknown")
        }
        return request
    }

    /// Posts that fail with a transient error before one lands.
    var failingPosts = 0
    private(set) var postAttempts = 0

    @MainActor func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws {
        postAttempts += 1
        if failingPosts > 0 {
            failingPosts -= 1
            throw LeoClientToolsError.other(code: nil, message: "connection reset")
        }
        results.append((requestID, outcome))
        postedWhileOpen.append(openStreams.value > 0)
    }

    @MainActor func pending() async throws -> [LeoClientToolPending] { pendingRequests }

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

    /// iOS's session: unowned requests wait out `claimDelay` on `clock`.
    private func deferringSession(_ clock: ClaimClock) -> LeoClientToolsSession {
        LeoClientToolsSession(
            host: .remote("dionysus"), client: client, executor: executor,
            isPlatformSupported: true, claimDelay: .milliseconds(1500), sleep: { try await clock.sleep(for: $0) }
        )
    }

    private static func request(_ id: String, tool: String = "browser_click", owner: String = "") -> LeoClientToolRequest {
        LeoClientToolRequest(id: id, agent: "alpha", group: "browser", tool: tool, args: .object(["ref": .string("s1e1")]), owner: owner, timeoutSeconds: 30)
    }

    private static func pending(_ id: String, owner: String = "", claimedBy: String = "") -> LeoClientToolPending {
        LeoClientToolPending(request: request(id, owner: owner), claimedBy: claimedBy)
    }

    private static func isCancelled(_ outcome: LeoClientToolOutcome?) -> Bool {
        guard case .failure(let error)? = outcome else { return false }
        return error.code == "cancelled"
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

    @Test func aResultWhosePostFailsIsPostedAgainOnTheSameStream() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [LeoClientToolPending(request: Self.request("ctr_1"), claimedBy: "")]
        client.failingPosts = 2

        client.send(.request(Self.request("ctr_1")))
        await until { executor.started == ["ctr_1"] }
        executor.finish("ctr_1")

        await until { client.results.count == 1 }
        #expect(client.postAttempts == 3)
        #expect(client.claims == ["ctr_1"])
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

    // MARK: - B-305: suspend, resume, ownership, claim delay

    @Test func suspendAnswersInFlightCancelledThenClosesStream() async {
        let clock = ClaimClock()
        let session = deferringSession(clock)
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [Self.pending("ctr_1", owner: "ct_1"), Self.pending("ctr_2")]
        client.send(.request(Self.request("ctr_1", owner: "ct_1")))
        await until { executor.started == ["ctr_1"] }
        client.send(.request(Self.request("ctr_2")))
        await until { clock.waiting == 1 }

        await session.suspend()

        #expect(client.results.map(\.id) == ["ctr_1"])
        #expect(Self.isCancelled(client.results.first?.outcome))
        #expect(client.postedWhileOpen == [true])
        await until { client.endedStreams == 1 }
        await until { executor.cancelled == ["ctr_1"] }

        clock.advance()
        for _ in 0..<50 { await Task.yield() }
        #expect(client.claims == ["ctr_1"])
        #expect(client.streams.count == 1)
        #expect(executor.started == ["ctr_1"])
    }

    @Test func resumeReregistersAndClaimsPending() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        await session.suspend()
        await until { client.endedStreams == 1 }
        client.pendingRequests = [Self.pending("ctr_9")]

        session.resume()
        await until { client.streams.count == 2 }
        client.send(.hello(clientID: "ct_2"))

        await until { client.registered.count == 2 }
        await until { executor.started == ["ctr_9"] }
        #expect(client.claims == ["ctr_9"])
    }

    @Test func deferredClaimYieldsToOwner() async {
        let clock = ClaimClock()
        let session = deferringSession(clock)
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [Self.pending("ctr_1"), Self.pending("ctr_2")]

        client.send(.request(Self.request("ctr_1")))
        client.send(.request(Self.request("ctr_2")))
        await until { clock.waiting == 2 }
        #expect(clock.durations == [.milliseconds(1500), .milliseconds(1500)])
        #expect(client.claims.isEmpty)

        // During the grace the Mac takes ctr_2; ctr_3 is already this client's.
        client.pendingRequests = [Self.pending("ctr_1"), Self.pending("ctr_2", owner: "ct_mac", claimedBy: "ct_mac"), Self.pending("ctr_3", owner: "ct_1")]
        client.send(.request(Self.request("ctr_3", owner: "ct_1")))
        await until { client.claims == ["ctr_3"] }

        clock.advance()
        await until { client.claims == ["ctr_3", "ctr_1"] }
        for _ in 0..<50 { await Task.yield() }
        #expect(client.claims == ["ctr_3", "ctr_1"])
        #expect(executor.started == ["ctr_3", "ctr_1"])
    }

    @Test func skipsRequestsOwnedByAnotherClient() async {
        let session = session()
        defer { session.stop() }
        await connected(session)
        client.pendingRequests = [Self.pending("ctr_1", owner: "ct_mac")]

        client.send(.request(Self.request("ctr_1", owner: "ct_mac")))
        client.send(.gap(expected: 3, received: 5))
        for _ in 0..<100 { await Task.yield() }

        #expect(client.claims.isEmpty)
        #expect(executor.started.isEmpty)
    }
}

/// A clock whose sleepers wait until the test advances it.
@MainActor final class ClaimClock {
    private var sleepers: [CheckedContinuation<Void, any Error>] = []
    private(set) var durations: [Duration] = []

    var waiting: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { sleepers.append($0) }
        try Task.checkCancellation()
    }

    /// Wakes every sleeper.
    func advance() {
        let woken = sleepers
        sleepers = []
        woken.forEach { $0.resume() }
    }
}

/// A count read and written from any thread.
final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func add(_ delta: Int) { lock.withLock { count += delta } }
}
