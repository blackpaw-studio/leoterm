import Foundation
import Testing

@testable import LeoKit

struct LeoTaskETATests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func task(
        percent: Double?, eta: Date? = nil, state: LeoAgentTask.State = .running, started: TimeInterval = 0
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: "build", title: "Build", mode: percent == nil ? .indeterminate : .determinate, percent: percent,
            etaAt: eta, state: state, startedAt: Date(timeIntervalSince1970: 1_000_000 + started)
        )
    }

    private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    @Test func agentSuppliedETAWins() {
        var eta = LeoTaskETA()
        let supplied = at(500)
        let t = task(percent: 10, eta: supplied)
        eta.observe(agent: "a", task: t, now: at(0))
        eta.observe(agent: "a", task: task(percent: 20, eta: supplied), now: at(60))
        #expect(eta.etaAt(agent: "a", task: t, now: at(60)) == supplied)
    }

    @Test func oneSampleGivesNoETA() {
        var eta = LeoTaskETA()
        let t = task(percent: 10)
        eta.observe(agent: "a", task: t, now: at(0))
        #expect(eta.etaAt(agent: "a", task: t, now: at(0)) == nil)
    }

    @Test func spanUnderThirtySecondsGivesNoETA() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 10), now: at(0))
        let t = task(percent: 20)
        eta.observe(agent: "a", task: t, now: at(29))
        #expect(eta.etaAt(agent: "a", task: t, now: at(29)) == nil)
    }

    @Test func linearETAFromTwoSamples() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 10), now: at(0))
        let t = task(percent: 20)
        eta.observe(agent: "a", task: t, now: at(60))
        // 10 points per 60 s; 80 left at t=60 -> 480 s more.
        #expect(eta.etaAt(agent: "a", task: t, now: at(60)) == at(540))
    }

    @Test func etaNeverLiesInThePast() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 10), now: at(0))
        let t = task(percent: 90)
        eta.observe(agent: "a", task: t, now: at(60))
        #expect(eta.etaAt(agent: "a", task: t, now: at(500)) == at(500))
    }

    @Test func flatProgressGivesNoETA() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 30), now: at(0))
        let t = task(percent: 30)
        eta.observe(agent: "a", task: t, now: at(120))
        #expect(eta.etaAt(agent: "a", task: t, now: at(120)) == nil)
    }

    @Test func fallingProgressGivesNoETA() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 50), now: at(0))
        let t = task(percent: 40)
        eta.observe(agent: "a", task: t, now: at(120))
        #expect(eta.etaAt(agent: "a", task: t, now: at(120)) == nil)
    }

    @Test func restartedRunStartsFresh() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 10), now: at(0))
        eta.observe(agent: "a", task: task(percent: 80), now: at(100))
        let rerun = task(percent: 5, started: 200)
        eta.observe(agent: "a", task: rerun, now: at(200))
        #expect(eta.etaAt(agent: "a", task: rerun, now: at(200)) == nil)
    }

    @Test func tasksAreKeyedPerAgent() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 10), now: at(0))
        let t = task(percent: 20)
        eta.observe(agent: "b", task: t, now: at(60))
        #expect(eta.etaAt(agent: "b", task: t, now: at(60)) == nil)
    }

    @Test func endedTaskHasNoETA() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 10), now: at(0))
        let t = task(percent: 100, state: .succeeded)
        eta.observe(agent: "a", task: t, now: at(60))
        #expect(eta.etaAt(agent: "a", task: t, now: at(60)) == nil)
    }

    @Test func forgetDropsSamples() {
        var eta = LeoTaskETA()
        eta.observe(agent: "a", task: task(percent: 10), now: at(0))
        eta.forget(agent: "a", id: "build")
        let t = task(percent: 20)
        eta.observe(agent: "a", task: t, now: at(60))
        #expect(eta.etaAt(agent: "a", task: t, now: at(60)) == nil)
    }

    @Test func indeterminateShowsElapsed() {
        let t = task(percent: nil, started: 10)
        #expect(LeoTaskETA.elapsed(of: t, now: at(130)) == 120)
        #expect(LeoTaskETA.elapsed(of: task(percent: 5), now: at(130)) == nil)
    }
}
