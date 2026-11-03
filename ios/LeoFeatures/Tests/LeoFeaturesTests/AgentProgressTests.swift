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

    @Test func aRunningDeterminateTaskShowsTitleStatusPercentAndEta() throws {
        let task = LeoAgentTask.make("build", title: "Xcode build", percent: 62, status: "Compiling 412/980")
        let eta = Self.now.addingTimeInterval(240)
        let progress = try #require(Self.agent([task], etas: ["build": eta]).progress(now: Self.now))
        #expect(progress.text == "Xcode build · Compiling 412/980 · 62% · 4m")
        #expect(progress.style == .determinate(0.62))
        #expect(progress.badge == nil)
    }

    @Test func anIndeterminateTaskShowsElapsedTime() throws {
        let progress = try #require(Self.agent([.make("sync", title: "Sync")]).progress(now: Self.now))
        #expect(progress.text == "Sync · 4m")
        #expect(progress.style == .indeterminate)
    }

    @Test func aStaleTaskIsMarkedAndDimmed() throws {
        let progress = try #require(Self.agent([.make("build", title: "Build", percent: 40, stale: true)]).progress(now: Self.now))
        #expect(progress.text == "Build · 40% · stale")
        #expect(progress.style == .stale(0.4))
    }

    @Test func aFailedTaskWinsAndShowsAFullRedBar() throws {
        let tasks = [
            LeoAgentTask.make("a", title: "Tests", percent: 10, updatedAt: progressEpoch.addingTimeInterval(100)),
            LeoAgentTask.make("b", title: "Deploy", state: .failed, endedAt: progressEpoch.addingTimeInterval(50)),
        ]
        let progress = try #require(Self.agent(tasks).progress(now: Self.now))
        #expect(progress.text == "Failed: Deploy")
        #expect(progress.style == .failed)
        #expect(progress.badge == "+1")
    }

    @Test(arguments: [LeoAttentionState.needsInput, .errored, .finished])
    func attentionHidesTheBar(_ state: LeoAttentionState) {
        #expect(Self.agent([.make("build", percent: 50)], attention: state).progress(now: Self.now) == nil)
    }

    @Test func workingAttentionStillShowsTheBar() {
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
