import Foundation
import Testing

@testable import LeoKit

struct LeoAgentTasksTests {
    private func task(_ id: String, _ state: LeoAgentTask.State = .running, updated: TimeInterval = 0, ended: TimeInterval? = nil) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: id, state: state, startedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updated), endedAt: ended.map(Date.init(timeIntervalSince1970:))
        )
    }

    @Test func emptyHasNoPrimary() {
        #expect(LeoAgentTasks.primary([]) == nil)
    }

    @Test func failedBeatsRunning() {
        let tasks = [task("run", updated: 100), task("bad", .failed, updated: 1, ended: 1)]
        #expect(LeoAgentTasks.primary(tasks)?.id == "bad")
    }

    @Test func newestFailedWins() {
        let tasks = [task("old", .failed, ended: 5), task("new", .failed, ended: 9)]
        #expect(LeoAgentTasks.primary(tasks)?.id == "new")
    }

    @Test func newestRunningWins() {
        let tasks = [task("a", updated: 5), task("b", updated: 9), task("done", .succeeded, updated: 99, ended: 99)]
        #expect(LeoAgentTasks.primary(tasks)?.id == "b")
    }

    @Test func runningBeatsFinished() {
        let tasks = [task("done", .succeeded, ended: 99), task("run", updated: 1)]
        #expect(LeoAgentTasks.primary(tasks)?.id == "run")
    }

    @Test func newestFinishedWhenNothingElse() {
        let tasks = [task("s", .succeeded, ended: 5), task("c", .cancelled, ended: 8)]
        #expect(LeoAgentTasks.primary(tasks)?.id == "c")
    }

    @Test func tieBreaksByIDForStability() {
        let tasks = [task("b", updated: 5), task("a", updated: 5)]
        #expect(LeoAgentTasks.primary(tasks)?.id == "a")
        #expect(LeoAgentTasks.primary(tasks.reversed())?.id == "a")
    }

    @Test func orderedIsFailedThenRunningThenEnded() {
        let tasks = [
            task("done", .succeeded, ended: 50), task("runOld", updated: 1), task("bad", .failed, ended: 2),
            task("runNew", updated: 9), task("cx", .cancelled, ended: 70), task("bad2", .failed, ended: 8),
        ]
        #expect(LeoAgentTasks.ordered(tasks).map(\.id) == ["bad2", "bad", "runNew", "runOld", "cx", "done"])
    }

    @Test func orderedFirstEqualsPrimary() {
        let tasks = [task("a", updated: 5), task("b", .succeeded, ended: 9)]
        #expect(LeoAgentTasks.ordered(tasks).first == LeoAgentTasks.primary(tasks))
        #expect(LeoAgentTasks.ordered([]).isEmpty)
    }

    @Test func orderedTiesBreakByID() {
        let tasks = [task("b", updated: 5), task("c", updated: 5), task("a", updated: 5)]
        #expect(LeoAgentTasks.ordered(tasks).map(\.id) == ["a", "b", "c"])
        #expect(LeoAgentTasks.ordered(tasks.reversed()).map(\.id) == ["a", "b", "c"])
    }
}
