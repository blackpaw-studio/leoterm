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
        #expect(LeoAgentTasks.extraCount([]) == 0)
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

    @Test func extraCountIsEveryOtherTask() {
        #expect(LeoAgentTasks.extraCount([task("a")]) == 0)
        #expect(LeoAgentTasks.extraCount([task("a"), task("b", .failed, ended: 1), task("c", .succeeded, ended: 1)]) == 2)
    }

    @Test func tieBreaksByIDForStability() {
        let tasks = [task("b", updated: 5), task("a", updated: 5)]
        #expect(LeoAgentTasks.primary(tasks)?.id == "a")
        #expect(LeoAgentTasks.primary(tasks.reversed())?.id == "a")
    }
}
