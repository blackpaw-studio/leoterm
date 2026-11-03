import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Agent tasks through the feed: seeded silently from `/state`, folded
/// from `agent_task_changed`, reported once when they finish live, shown
/// only while the host advertises `agent_progress` and is connected.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedProgressTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func task(
        _ id: String = "build", state: LeoAgentTask.State = .running, percent: Double? = 10, revision: Int = 1, ended: Date? = nil
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: "Xcode build", mode: .determinate, percent: percent, state: state, startedAt: t0,
            updatedAt: t0.addingTimeInterval(Double(revision)), endedAt: ended, revision: revision
        )
    }

    private static func hello(_ features: [String] = ["agent_progress"]) -> LeoObserveEvent {
        .hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: features)
    }

    private static func changed(_ task: LeoAgentTask?, id: String = "build", seq: Int = 2) -> LeoObserveEvent {
        .agentTaskChanged(seq: seq, at: nil, agent: "alpha", id: id, task: task)
    }

    private actor Finishes {
        private(set) var values: [LeoTaskFinish] = []
        func add(_ finishes: [LeoTaskFinish]) { values += finishes }
    }

    private func started(_ harness: TurnHarness, seed: [LeoAgentTask] = [], features: [String] = ["agent_progress"]) async throws {
        await harness.activity.setTasks(seed)
        await harness.start()
        await harness.activity.send(Self.hello(features))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
    }

    @Test func seedsFromState() async throws {
        let harness = TurnHarness()
        try await started(harness, seed: [Self.task()])
        try await harness.pump { $0.rows.first?.tasks.tasks == [Self.task()] }
        await harness.stop()
    }

    @Test func eventUpsertsThenNullRemoves() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.changed(Self.task(percent: 40, revision: 2)))
        try await harness.pump { $0.rows.first?.tasks.primary?.percent == 40 }
        await harness.activity.send(Self.changed(nil, seq: 3))
        try await harness.pump { $0.rows.first?.tasks.isEmpty == true }
        await harness.stop()
    }

    @Test func olderDaemonShowsNothing() async throws {
        let harness = TurnHarness()
        try await started(harness, seed: [Self.task()], features: [])
        await harness.activity.send(Self.changed(Self.task(revision: 2)))
        await harness.settle()
        let rows = await harness.recorder.values.flatMap(\.rows)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.tasks.isEmpty })
        await harness.stop()
    }

    @Test func disconnectedRowsShowNothing() async throws {
        let harness = TurnHarness()
        try await started(harness, seed: [Self.task()])
        try await harness.pump { $0.rows.first?.tasks.isEmpty == false }
        await harness.activity.send(.disconnected(reason: "EOF"))
        try await harness.pump { $0.connectivity.isDisconnected }
        #expect(await harness.recorder.last?.rows.first?.tasks.isEmpty == true)
        await harness.stop()
    }

    @Test func agentStopClearsItsTasks() async throws {
        let harness = TurnHarness()
        try await started(harness, seed: [Self.task()])
        try await harness.pump { $0.rows.first?.tasks.isEmpty == false }
        await harness.activity.setTasks([])
        await harness.activity.send(.agentStopped(seq: 3, at: nil, agent: "alpha", wakeOnMessage: nil))
        try await harness.pump { $0.rows.first?.tasks.isEmpty == true }
        await harness.stop()
    }

    @Test func liveFinishIsReportedOnceAndBaselineReplayIsSilent() async throws {
        let finishes = Finishes()
        let harness = TurnHarness(onTaskFinishes: { _, list in Task { await finishes.add(list) } })
        try await started(harness, seed: [Self.task()])
        try await harness.pump { $0.rows.first?.tasks.isEmpty == false }
        let done = Self.task(state: .succeeded, percent: 100, revision: 2, ended: Self.t0.addingTimeInterval(60))
        await harness.activity.send(Self.changed(done))
        try await until { await finishes.values.count == 1 }
        // The same finish again (a replay) and a baseline holding it: silent.
        await harness.activity.send(Self.changed(done, seq: 3))
        await harness.activity.setTasks([done])
        await harness.activity.send(Self.hello())
        await harness.settle()
        #expect(await finishes.values == [LeoTaskFinish(agent: "alpha", task: done)])
        await harness.stop()
    }

    @Test func noFinishWithoutTheAdvertisedFeature() async throws {
        let finishes = Finishes()
        let harness = TurnHarness(onTaskFinishes: { _, list in Task { await finishes.add(list) } })
        try await started(harness, seed: [Self.task()], features: [])
        await harness.activity.send(Self.changed(Self.task(state: .failed, revision: 2, ended: Self.t0.addingTimeInterval(5))))
        await harness.settle()
        #expect(await finishes.values.isEmpty)
        await harness.stop()
    }

    @Test func aReconnectSnapshotShowingARunningTaskSucceededUpdatesSilently() async throws {
        let finishes = Finishes()
        let harness = TurnHarness(onTaskFinishes: { _, list in Task { await finishes.add(list) } })
        try await started(harness, seed: [Self.task()])
        try await harness.pump { $0.rows.first?.tasks.primary?.state == .running }
        let done = Self.task(state: .succeeded, percent: 100, revision: 2, ended: Self.t0.addingTimeInterval(60))
        await harness.activity.setTasks([done])
        await harness.activity.send(Self.hello())
        try await harness.pump { $0.rows.first?.tasks.primary?.state == .succeeded }
        await harness.settle()
        #expect(await finishes.values.isEmpty)
        await harness.stop()
    }
}
