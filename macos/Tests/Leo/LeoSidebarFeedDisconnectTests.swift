import Foundation
import Testing

@testable import Ghostty

/// B-007 / D-061: a dropped stream, a dead tunnel or a failed wake check
/// puts the feed in `.disconnected`: rows stay (activity cleared) but no
/// refresh, poll or stream runs until the user's Retry -- which, for the
/// same host, keeps the rows dimmed until the new connection's list lands.
struct LeoSidebarFeedDisconnectTests {
    @Test func aDroppedStreamKeepsTheRowsAndStopsEveryTimer() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected && $0.rows.map(\.name) == ["alpha"] }

        await harness.activity.send(.disconnected(reason: "Connection closed"))

        await harness.waitFor { $0.connectivity == .disconnected(reason: "Connection closed", isRetrying: false) }
        let snapshot = try #require(await harness.recorder.last)
        #expect(snapshot.rows.map(\.name) == ["alpha"])
        #expect(snapshot.rows.allSatisfy { $0.activity == .unknown })
        await harness.settle()
        #expect(await harness.clock.waiterCount == 0, "no poll or retry timer may run while disconnected")
        await harness.stop()
    }

    @Test func nothingRefreshesWhileDisconnected() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        await harness.activity.send(.disconnected(reason: "Connection closed"))
        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }
        let calls = await harness.daemon.listCallCount

        await harness.feed.refresh()
        await harness.feed.tick()
        await harness.feed.setPolling(false)
        await harness.feed.setPolling(true)
        await harness.settle()

        #expect(await harness.daemon.listCallCount == calls)
        #expect(await harness.clock.waiterCount == 0)
        await harness.stop()
    }

    @Test func aDisconnectedSnapshotHasNoBadgesAndNoDockCount() async throws {
        let harness = DisconnectHarness(
            results: [.success(["alpha"])],
            state: [.init(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil,
                          attention: .init(state: .needsInput, revision: 3))]
        )
        await harness.connect()
        await harness.waitFor { $0.attentionCount == 1 }

        await harness.activity.send(.disconnected(reason: "Connection closed"))

        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }
        let snapshot = try #require(await harness.recorder.last)
        #expect(snapshot.attentionCount == 0)
        #expect(snapshot.rows.allSatisfy { $0.attention == nil })
        await harness.stop()
    }

    @Test func retryKeepsTheRowsDimmedUntilTheNewListLands() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        await harness.activity.send(.disconnected(reason: "Connection closed"))
        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }

        let retryDaemon = DisconnectDaemon(results: [])
        let retryActivity = DisconnectActivity()
        await harness.feed.updateConnection(host: .local, generation: 2, phase: .connecting)
        await harness.waitFor { $0.connectivity == .disconnected(reason: "Connection closed", isRetrying: true) }
        #expect(await harness.recorder.last?.rows.map(\.name) == ["alpha"])

        await harness.feed.updateConnection(host: .local, generation: 2, phase: .connected(daemon: retryDaemon, activitySource: retryActivity.source))
        await awaitCondition { await retryDaemon.listCallCount == 1 }
        #expect(await harness.recorder.last?.connectivity == .disconnected(reason: "Connection closed", isRetrying: true))

        await retryDaemon.resolve(.success(["alpha", "beta"]))
        await harness.waitFor { $0.connectivity == .connected && $0.rows.map(\.name) == ["alpha", "beta"] }
        await harness.stop()
    }

    @Test func aFailedRetryKeepsTheBannerWithTheNewReason() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        await harness.activity.send(.disconnected(reason: "Connection closed"))
        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }

        let retryDaemon = DisconnectDaemon(results: [.failure(LeoDaemonError.transport("refused"))])
        await harness.feed.updateConnection(
            host: .local, generation: 2,
            phase: .connected(daemon: retryDaemon, activitySource: DisconnectActivity().source)
        )

        let reason = LeoDaemonError.transport("refused").localizedDescription
        await harness.waitFor { $0.connectivity == .disconnected(reason: reason, isRetrying: false) }
        #expect(await harness.recorder.last?.rows.map(\.name) == ["alpha"])
        await harness.settle()
        #expect(await harness.clock.waiterCount == 0)
        await harness.stop()
    }

    @Test func aTunnelThatFailsDuringRetryKeepsTheBanner() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])], host: .remote("mars"))
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        await harness.activity.send(.disconnected(reason: "Connection closed"))
        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }

        await harness.feed.updateConnection(host: .remote("mars"), generation: 2, phase: .connecting)
        await harness.feed.updateConnection(host: .remote("mars"), generation: 2, phase: .failed(message: "ssh exited (255)"))

        await harness.waitFor { $0.connectivity == .disconnected(reason: "ssh exited (255)", isRetrying: false) }
        #expect(await harness.recorder.last?.rows.map(\.name) == ["alpha"])
        await harness.stop()
    }

    /// Tunnel drop: `LeoHostSelection` publishes `.failed` for the live
    /// connection's own generation.
    @Test func aTunnelDropOnALiveConnectionIsDisconnectedNotFailed() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])], host: .remote("mars"))
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }

        await harness.feed.updateConnection(host: .remote("mars"), generation: 1, phase: .failed(message: "ssh exited (255)"))

        await harness.waitFor { $0.connectivity == .disconnected(reason: "ssh exited (255)", isRetrying: false) }
        #expect(await harness.recorder.last?.rows.map(\.name) == ["alpha"])
        await harness.stop()
    }

    @Test func aConnectFailureThatWasNeverLiveStaysFailed() async throws {
        let harness = DisconnectHarness(results: [])
        await harness.feed.start()
        await harness.feed.setInitialPolling(true)

        await harness.feed.updateConnection(host: .remote("mars"), generation: 1, phase: .failed(message: "Unknown host mars"))

        await harness.waitFor { $0.connectivity == .failed(message: "Unknown host mars") }
        await harness.stop()
    }

    @Test func switchingToAnotherHostWhileDisconnectedStartsClean() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        await harness.activity.send(.disconnected(reason: "Connection closed"))
        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }

        await harness.feed.updateConnection(host: .remote("mars"), generation: 2, phase: .connecting)

        await harness.waitFor { $0.connectivity == .loading && $0.rows.isEmpty }
        await harness.stop()
    }

    @Test func aFailedWakeCheckDisconnects() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"]), .failure(LeoDaemonError.timeout)])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }

        await harness.feed.checkLiveness()

        let reason = LeoDaemonError.timeout.localizedDescription
        await harness.waitFor { $0.connectivity == .disconnected(reason: reason, isRetrying: false) }
        #expect(await harness.daemon.listCallCount == 2)
        await harness.stop()
    }

    @Test func aPassingWakeCheckChangesNothingAndIsNotRepeated() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"]), .success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        let emitted = await harness.recorder.count

        await harness.feed.checkLiveness()
        await awaitCondition { await harness.daemon.listCallCount == 2 }
        await harness.settle()

        #expect(await harness.daemon.listCallCount == 2, "one check per wake, never a loop")
        #expect(await harness.recorder.count == emitted)
        #expect(await harness.recorder.last?.connectivity == .connected)
        await harness.stop()
    }

    @Test func noWakeCheckRunsWhileAlreadyDisconnected() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        await harness.activity.send(.disconnected(reason: "Connection closed"))
        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }

        await harness.feed.checkLiveness()
        await harness.settle()

        #expect(await harness.daemon.listCallCount == 1)
        await harness.stop()
    }

    /// `LeoRuntime` forwards each phase in its own task, so an older
    /// generation's phase can land after a newer Retry connected. It must
    /// never reset or disconnect the live sidebar.
    @Test func phasesFromAnOlderGenerationNeverReplaceALiveRetry() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])], host: .remote("mars"))
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }
        await harness.activity.send(.disconnected(reason: "Connection closed"))
        await harness.waitFor { if case .disconnected = $0.connectivity { true } else { false } }

        let retryDaemon = DisconnectDaemon(results: [.success(["alpha", "beta"])])
        await harness.feed.updateConnection(
            host: .remote("mars"), generation: 3,
            phase: .connected(daemon: retryDaemon, activitySource: DisconnectActivity().source)
        )
        await harness.waitFor { $0.connectivity == .connected && $0.rows.map(\.name) == ["alpha", "beta"] }
        let emitted = await harness.recorder.count

        await harness.feed.updateConnection(host: .remote("mars"), generation: 2, phase: .connecting)
        await harness.feed.updateConnection(host: .remote("mars"), generation: 2, phase: .failed(message: "stale"))
        await harness.feed.updateConnection(host: .remote("mars"), generation: 1, phase: .failed(message: "older"))
        await harness.settle()

        #expect(await harness.recorder.count == emitted)
        #expect(await harness.recorder.last?.connectivity == .connected)
        #expect(await harness.recorder.last?.rows.map(\.name) == ["alpha", "beta"])
        await harness.feed.refresh()
        await awaitCondition { await retryDaemon.listCallCount == 2 }
        await harness.stop()
    }

    /// Within one generation, `.connecting` always precedes `.connected`;
    /// a late one is stale and must not take the host down.
    @Test func aLateConnectingForTheLiveGenerationIsIgnored() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"]), .success(["alpha"])], host: .remote("mars"))
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }

        await harness.feed.updateConnection(host: .remote("mars"), generation: 1, phase: .connecting)
        await harness.feed.refresh()

        await awaitCondition { await harness.daemon.listCallCount == 2 }
        #expect(await harness.recorder.last?.connectivity == .connected)
        await harness.stop()
    }

    /// `applyConnected` can be overtaken by the tunnel's `.failed` for the
    /// same generation: once that generation has failed, its late
    /// `.connected` must not bring the dead connection back.
    @Test func aLateConnectedAfterItsGenerationFailedIsIgnored() async throws {
        let harness = DisconnectHarness(results: [])
        await harness.feed.start()
        await harness.feed.setInitialPolling(true)
        await harness.feed.updateConnection(host: .remote("mars"), generation: 1, phase: .connecting)
        await harness.feed.updateConnection(host: .remote("mars"), generation: 1, phase: .failed(message: "ssh exited (255)"))
        await harness.waitFor { $0.connectivity == .failed(message: "ssh exited (255)") }

        let lateDaemon = DisconnectDaemon(results: [.success(["ghost"])])
        await harness.feed.updateConnection(
            host: .remote("mars"), generation: 1,
            phase: .connected(daemon: lateDaemon, activitySource: DisconnectActivity().source)
        )
        await harness.feed.refresh()
        await harness.settle()

        #expect(await lateDaemon.listCallCount == 0)
        #expect(await harness.recorder.last?.connectivity == .failed(message: "ssh exited (255)"))
        await harness.stop()
    }

    /// A superseded wake check's failure (e.g. one whose error was already
    /// on its way when the next wake cancelled it) never disconnects.
    @Test func aStaleWakeCheckFailureIsIgnored() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }

        let first = await harness.feed.checkLiveness()
        let second = await harness.feed.checkLiveness()
        await harness.daemon.resolve(.success(["alpha"]))
        await harness.feed.livenessCheckFinished(.failure(LeoDaemonError.timeout), token: try #require(first))
        await harness.settle()

        #expect(second != first)
        #expect(await harness.recorder.last?.connectivity == .connected)
        await harness.stop()
    }

    @Test func disconnectRequestEntersTheSameState() async throws {
        let harness = DisconnectHarness(results: [.success(["alpha"])])
        await harness.connect()
        await harness.waitFor { $0.connectivity == .connected }

        await harness.feed.disconnect(reason: "Forced")

        await harness.waitFor { $0.connectivity == .disconnected(reason: "Forced", isRetrying: false) }
        #expect(await harness.recorder.last?.rows.map(\.name) == ["alpha"])
        await harness.stop()
    }
}

private struct DisconnectHarness {
    let daemon: DisconnectDaemon
    let activity = DisconnectActivity()
    let recorder = DisconnectRecorder()
    let clock = DisconnectClock()
    let feed: LeoSidebarFeed
    let host: LeoHostID
    let state: [LeoObservedAgent]

    init(results: [Result<[String], Error>], state: [LeoObservedAgent] = [], host: LeoHostID = .local) {
        daemon = DisconnectDaemon(results: results)
        self.host = host
        self.state = state
        let recorder = recorder
        let clock = clock
        feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            sleep: { try await clock.sleep($0) },
            now: { 0 },
            sink: { snapshot in Task { await recorder.append(snapshot) } }
        )
    }

    func connect() async {
        await activity.setState(state)
        await feed.start()
        await feed.setInitialPolling(true)
        await feed.updateConnection(host: host, generation: 1, phase: .connected(daemon: daemon, activitySource: activity.source))
    }

    func stop() async { await feed.stop() }

    func waitFor(_ condition: @escaping @Sendable (LeoSidebarSnapshot) -> Bool) async {
        await awaitCondition(timeout: 2) { await recorder.last.map(condition) ?? false }
    }

    /// Lets every task the last call started run to its next suspension.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private actor DisconnectRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    var count: Int { values.count }
    func append(_ value: LeoSidebarSnapshot) { values.append(value) }
}

private actor DisconnectActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private var state: [LeoObservedAgent] = []

    init() { (stream, continuation) = AsyncStream.makeStream() }

    nonisolated var source: LeoSidebarActivitySource {
        .init(events: { await self.events() }, fetchState: { await self.fetchState() })
    }

    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func fetchState() -> [LeoObservedAgent] { state }
    func setState(_ state: [LeoObservedAgent]) { self.state = state }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
}

/// Answers `listAgents` from `results` in order; once they run out, parks
/// the call until `resolve`.
private actor DisconnectDaemon: LeoDaemonClient {
    private var results: [Result<[String], Error>]
    private var waiters: [CheckedContinuation<Result<[String], Error>, Never>] = []
    private(set) var listCallCount = 0

    init(results: [Result<[String], Error>]) { self.results = results }

    func listAgents() async throws -> [LeoAgent] {
        listCallCount += 1
        let result = results.isEmpty ? await withCheckedContinuation { waiters.append($0) } : results.removeFirst()
        return try result.get().map {
            LeoAgent(name: $0, template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running,
                     startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
        }
    }

    func resolve(_ result: Result<[String], Error>) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: result)
    }

    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}

/// Never fires on its own: a parked sleep is a pending timer, so
/// `waiterCount` is the number of timers alive right now.
private actor DisconnectClock {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var waiterCount: Int { waiters.count }

    func sleep(_: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(
            operation: { try await withCheckedThrowingContinuation { waiters[id] = $0 } },
            onCancel: { Task { await self.cancel(id) } }
        )
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
