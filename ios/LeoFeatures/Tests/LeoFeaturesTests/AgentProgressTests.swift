import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

struct AgentProgressTests {
    static let now = progressEpoch.addingTimeInterval(240)

    static func agent(_ tasks: [LeoAgentTask], attention: LeoAttentionState? = nil, etas: [String: Date] = [:]) -> Agent {
        var agent = Agent(name: "zeus", status: .running, activity: .working, attention: attention.map { LeoAttentionSignal(state: $0, revision: 1) })
        agent.tasks = tasks
        agent.taskETAs = etas
        return agent
    }

    @Test func noTasksMeansNoProgress() {
        #expect(Self.agent([]).progress(now: Self.now) == nil)
    }

    @Test func aRunningDeterminateTaskShowsAPieAndItsTitle() throws {
        let task = LeoAgentTask.make("build", title: "Xcode build", percent: 62, status: "Compiling 412/980")
        let eta = Self.now.addingTimeInterval(240)
        let progress = try #require(Self.agent([task], etas: ["build": eta]).progress(now: Self.now))
        #expect(progress.text == "Xcode build")
        #expect(progress.indicator == .progress(fraction: 0.62))
        #expect(progress.spokenValue == "Xcode build, 62 percent")
        #expect(progress.tooltip == "Xcode build · Compiling 412/980 · 62% · 4m")
    }

    @Test func anIndeterminateTaskShowsTheSpinner() throws {
        let progress = try #require(Self.agent([.make("sync", title: "Sync")]).progress(now: Self.now))
        #expect(progress.text == "Sync")
        #expect(progress.indicator == .progress(fraction: nil))
    }

    @Test func aStaleTaskIsMutedAndSaysHowLongAgo() throws {
        let task = LeoAgentTask.make("build", title: "Build", percent: 40, stale: true, updatedAt: progressEpoch)
        let progress = try #require(Self.agent([task]).progress(now: Self.now))
        #expect(progress.text == "Build · no update for 4m")
        #expect(progress.indicator == .stalled(fraction: 0.4))
    }

    @Test func aFailedTaskWinsTheTextAndShowsTheGlyphWhileNothingIsLive() throws {
        let tasks = [
            LeoAgentTask.make("a", title: "Tests", percent: 10, state: .cancelled, endedAt: progressEpoch.addingTimeInterval(100)),
            LeoAgentTask.make("b", title: "Deploy", state: .failed, endedAt: progressEpoch.addingTimeInterval(50)),
        ]
        let progress = try #require(Self.agent(tasks).progress(now: Self.now))
        #expect(progress.text == "Failed: Deploy")
        #expect(progress.indicator == .failed)
    }

    @Test func severalRunningTasksNameTheOthers() throws {
        let tasks = [
            LeoAgentTask.make("a", title: "Sweep", percent: 40, updatedAt: progressEpoch.addingTimeInterval(100)),
            LeoAgentTask.make("b", title: "Lint", percent: 60), LeoAgentTask.make("c", title: "Docs"),
        ]
        let progress = try #require(Self.agent(tasks).progress(now: Self.now))
        #expect(progress.text == "Sweep and 2 more")
        #expect(progress.spokenValue == "Sweep and 2 more, 50 percent")
    }

    @Test func aFinishedTaskLeavesTheRowItsOwnSummary() throws {
        let task = LeoAgentTask.make("build", state: .succeeded, endedAt: progressEpoch)
        let progress = try #require(Self.agent([task]).progress(now: Self.now))
        #expect(progress.text == nil)
        #expect(progress.indicator == nil)
    }

    @Test(arguments: [LeoAttentionState.needsInput, .errored, .finished])
    func attentionHidesTheIndicator(_ state: LeoAttentionState) {
        #expect(Self.agent([.make("build", percent: 50)], attention: state).progress(now: Self.now) == nil)
    }

    @Test func workingAttentionStillShowsTheIndicator() {
        #expect(Self.agent([.make("build", percent: 50)], attention: .working).progress(now: Self.now) != nil)
    }
}

struct TaskDetailLineTests {
    static let now = progressEpoch.addingTimeInterval(240)

    @Test func aRunningTaskReadsStatusPercentAndEta() {
        var agent = Agent(name: "zeus")
        let task = LeoAgentTask.make("build", percent: 62, status: "Compiling 412/980")
        agent.taskETAs["build"] = Self.now.addingTimeInterval(90)
        #expect(agent.taskDetailLine(task, now: Self.now) == "Compiling 412/980 · 62% · 1m")
    }

    @Test func aFailedTaskLeadsWithFailedThenItsStatus() {
        let task = LeoAgentTask.make("build", state: .failed, status: "exit 2", endedAt: progressEpoch)
        #expect(Agent(name: "zeus").taskDetailLine(task, now: Self.now) == "Failed · exit 2")
    }
}
