import Foundation
import Testing

@testable import LeoKit

struct LeoTaskReducerTests {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }

    private func task(
        _ id: String = "build", _ state: LeoAgentTask.State = .running, revision: Int = 1,
        started: TimeInterval = 0, ended: TimeInterval? = nil
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: id, state: state, startedAt: date(started), updatedAt: date(started + Double(revision)),
            endedAt: ended.map(date), revision: revision
        )
    }

    private func agent(_ name: String, _ tasks: [LeoAgentTask]) -> LeoObservedAgent {
        LeoObservedAgent(name: name, status: nil, activity: nil, currentAction: nil, lastActivityAt: nil, tasks: tasks)
    }

    private func event(_ agent: String, _ id: String, _ task: LeoAgentTask?, seq: Int = 1) -> LeoObserveEvent {
        .agentTaskChanged(seq: seq, at: nil, agent: agent, id: id, task: task)
    }

    @Test func snapshotReplacesEverything() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(snapshot: [agent("a", [task("x")]), agent("b", [task("y")])])
        _ = reducer.apply(snapshot: [agent("a", [task("z")])])
        #expect(reducer.tasks(for: "a").map(\.id) == ["z"])
        #expect(reducer.tasks(for: "b").isEmpty)
    }

    @Test func snapshotReplayIsSilent() {
        var reducer = LeoTaskReducer()
        let finishes = reducer.apply(snapshot: [agent("a", [task("x", .succeeded, ended: 5), task("y", .failed, ended: 6)])])
        #expect(finishes.isEmpty)
    }

    @Test func liveFinishEmitsOnce() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(snapshot: [agent("a", [task()])])
        let done = task("build", .succeeded, revision: 2, ended: 10)
        let first = reducer.apply(event: event("a", "build", done))
        #expect(first == [LeoTaskFinish(agent: "a", task: done)])
        let again = reducer.apply(event: event("a", "build", task("build", .succeeded, revision: 3, ended: 10)))
        #expect(again.isEmpty)
    }

    @Test func failureEmitsFinishCancelDoesNot() {
        var reducer = LeoTaskReducer()
        let failed = task("f", .failed, revision: 2, ended: 5)
        #expect(reducer.apply(event: event("a", "f", failed)).count == 1)
        #expect(reducer.apply(event: event("a", "c", task("c", .cancelled, revision: 2, ended: 5))).isEmpty)
    }

    @Test func replayAfterReconnectStaysSilent() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(event: event("a", "build", task("build", .succeeded, revision: 2, ended: 10)))
        let finishes = reducer.apply(snapshot: [agent("a", [task("build", .succeeded, revision: 2, ended: 10)])])
        #expect(finishes.isEmpty)
        #expect(reducer.apply(event: event("a", "build", task("build", .succeeded, revision: 2, ended: 10))).isEmpty)
    }

    @Test func newerRunFinishesAgain() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(event: event("a", "build", task("build", .succeeded, revision: 2, started: 0, ended: 10)))
        let rerun = task("build", .succeeded, revision: 5, started: 100, ended: 160)
        #expect(reducer.apply(event: event("a", "build", rerun)) == [LeoTaskFinish(agent: "a", task: rerun)])
    }

    @Test func duplicateAndOlderRevisionsAreIgnored() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(event: event("a", "build", task(revision: 5)))
        _ = reducer.apply(event: event("a", "build", task(revision: 5)))
        _ = reducer.apply(event: event("a", "build", task(revision: 3)))
        #expect(reducer.tasks(for: "a").first?.revision == 5)
        _ = reducer.apply(event: event("a", "build", task(revision: 6)))
        #expect(reducer.tasks(for: "a").first?.revision == 6)
    }

    @Test func olderRunIsIgnored() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(event: event("a", "build", task(revision: 9, started: 100)))
        _ = reducer.apply(event: event("a", "build", task(revision: 10, started: 0)))
        #expect(reducer.tasks(for: "a").first?.startedAt == date(100))
    }

    @Test func nullRemovesTheTask() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(snapshot: [agent("a", [task("x"), task("y")])])
        _ = reducer.apply(event: event("a", "x", nil))
        #expect(reducer.tasks(for: "a").map(\.id) == ["y"])
        _ = reducer.apply(event: event("a", "y", nil))
        #expect(reducer.allTasks.isEmpty)
    }

    @Test func removedThenRecreatedStartsOver() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(event: event("a", "build", task(revision: 9)))
        _ = reducer.apply(event: event("a", "build", nil))
        _ = reducer.apply(event: event("a", "build", task(revision: 1, started: 500)))
        #expect(reducer.tasks(for: "a").first?.revision == 1)
    }

    @Test func agentStoppedClearsItsTasks() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(snapshot: [agent("a", [task()]), agent("b", [task()])])
        _ = reducer.apply(event: .agentStopped(seq: 2, at: nil, agent: "a", wakeOnMessage: nil))
        #expect(reducer.tasks(for: "a").isEmpty)
        #expect(!reducer.tasks(for: "b").isEmpty)
    }

    @Test func otherEventsAreIgnored() {
        var reducer = LeoTaskReducer()
        _ = reducer.apply(snapshot: [agent("a", [task()])])
        #expect(reducer.apply(event: .other(seq: 3, type: "x")).isEmpty)
        #expect(reducer.tasks(for: "a").count == 1)
    }
}
