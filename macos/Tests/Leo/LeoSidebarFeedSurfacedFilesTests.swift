import Foundation
import Testing

@testable import Ghostty

/// B-013 through the feed: `file_surfaced` events and `/state`'s
/// `surfaced_files` reach rows of the matching incarnation only, an id is
/// kept once, and an old daemon changes nothing.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedSurfacedFilesTests {
    @Test func aLiveEventPaintsTheMatchingRowOnce() async throws {
        let harness = SurfacedHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1")])
        await harness.start()
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()

        let file = surfaced("u-1", agent: "alpha", startedAt: "s1", line: 4, reason: "done")
        await harness.activity.send(.fileSurfaced(seq: 2, file: file))
        try await harness.pump { $0.rows.first?.surfacedFiles == [file] }

        await harness.activity.send(.fileSurfaced(seq: 3, file: file))
        await harness.settle()
        #expect(await harness.recorder.last?.rows.first?.surfacedFiles == [file], "a duplicate id is kept once")
        await harness.stop()
    }

    @Test func anEventForAnotherIncarnationNeverPaintsTheRow() async throws {
        let harness = SurfacedHarness(agents: [("alpha", "s2")], state: [observed("alpha", "s2")])
        await harness.start()
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()

        await harness.activity.send(.fileSurfaced(seq: 2, file: surfaced("u-old", agent: "alpha", startedAt: "s1")))
        await harness.settle()
        let painted = await harness.recorder.values.flatMap(\.rows).flatMap(\.surfacedFiles)
        #expect(painted.isEmpty)
        await harness.stop()
    }

    @Test func stateRecoversSurfacedFilesOnColdStart() async throws {
        let files = [surfaced("u-1", agent: "alpha", startedAt: "s1"), surfaced("u-2", agent: "alpha", startedAt: "s1")]
        let harness = SurfacedHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", files: files)])
        await harness.start()
        try await harness.pump { $0.rows.first?.surfacedFiles.map(\.id) == ["u-1", "u-2"] }
        await harness.stop()
    }

    @Test func anOldDaemonLeavesRowsBare() async throws {
        let harness = SurfacedHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1")])
        await harness.start()
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()
        #expect(await harness.recorder.values.flatMap(\.rows).allSatisfy { $0.surfacedFiles.isEmpty })
        await harness.stop()
    }

    @Test func disconnectingHidesSurfacedFiles() async throws {
        let harness = SurfacedHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", files: [surfaced("u-1", agent: "alpha", startedAt: "s1")])])
        await harness.start()
        try await harness.pump { $0.rows.first?.surfacedFiles.isEmpty == false }
        await harness.activity.send(.disconnected(reason: "gone"))
        try await harness.pump { $0.connectivity.isDisconnected }
        #expect(await harness.recorder.last?.rows.first?.surfacedFiles.isEmpty == true)
        await harness.stop()
    }

    @Test func aHostSwitchForgetsTheOldHostsFiles() async throws {
        let harness = SurfacedHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", files: [surfaced("u-1", agent: "alpha", startedAt: "s1")])])
        await harness.start()
        try await harness.pump { $0.rows.first?.surfacedFiles.isEmpty == false }

        // Host B has a namesake with the very same started_at.
        let daemonB = SurfacedDaemon(agents: [("alpha", "s1")])
        let activityB = SurfacedActivity(state: [observed("alpha", "s1")])
        await harness.feed.updateConnection(
            host: .remote("work"), generation: 1,
            phase: .connected(daemon: daemonB, activitySource: .init(events: { await activityB.events() }, fetchState: { await activityB.fetchState() }))
        )
        try await harness.pump { $0.rows.first?.host == .remote("work") }
        await harness.settle()
        let remote = await harness.recorder.values.flatMap(\.rows).filter { $0.host == .remote("work") }
        #expect(remote.allSatisfy { $0.surfacedFiles.isEmpty })
        await harness.stop()
    }
}

private func observed(_ name: String, _ startedAt: String, files: [LeoSurfacedFile] = []) -> LeoObservedAgent {
    LeoObservedAgent(
        name: name, status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, startedAt: startedAt,
        surfacedFiles: files
    )
}

private struct SurfacedHarness {
    let clock = SurfacedClock()
    let activity: SurfacedActivity
    let daemon: SurfacedDaemon
    let recorder = SurfacedRecorder<LeoSidebarSnapshot>()
    let feed: LeoSidebarFeed

    init(agents: [(String, String)], state: [LeoObservedAgent]) {
        let activity = SurfacedActivity(state: state)
        let daemon = SurfacedDaemon(agents: agents)
        self.activity = activity
        self.daemon = daemon
        let clock = clock
        let recorder = recorder
        feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(events: { await activity.events() }, fetchState: { await activity.fetchState() }),
            sleep: { try await clock.sleep($0) },
            now: { 0 },
            sink: { snapshot in Task { await recorder.append(snapshot) } }
        )
    }

    func start() async {
        await feed.start()
        await feed.setPolling(true)
    }

    func stop() async { await feed.stop() }

    func pump(_ condition: @escaping @Sendable (LeoSidebarSnapshot) -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until(sourceLocation: sourceLocation) {
            if let last = await recorder.last, condition(last) { return true }
            await clock.advanceAll()
            return false
        }
    }

    func settle() async {
        for _ in 0..<8 {
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor SurfacedActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private let state: [LeoObservedAgent]

    init(state: [LeoObservedAgent]) {
        self.state = state
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
    func fetchState() -> [LeoObservedAgent] { state }
}

private actor SurfacedDaemon: LeoDaemonClient {
    private let agents: [(String, String)]

    init(agents: [(String, String)]) { self.agents = agents }

    func listAgents() async throws -> [LeoAgent] {
        agents.map {
            LeoAgent(
                name: $0.0, template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running,
                startedAt: $0.1, restarts: nil, stoppedReason: nil, wakeOnMessage: nil
            )
        }
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

private actor SurfacedRecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    var last: Value? { values.last }
    func append(_ value: Value) { values.append(value) }
}

private actor SurfacedClock {
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextID = 0
    func sleep(_ nanoseconds: UInt64) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func advanceAll() {
        let pending = waiters
        waiters = [:]
        pending.values.forEach { $0.resume() }
    }
    private func cancel(_ id: Int) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
