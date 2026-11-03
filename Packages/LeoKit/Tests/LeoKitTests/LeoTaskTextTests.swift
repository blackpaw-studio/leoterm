import Foundation
import Testing

@testable import LeoKit

struct LeoTaskTextTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func task(
        title: String = "Xcode build", percent: Double? = 62, status: String? = "Compiling 412/980",
        state: LeoAgentTask.State = .running, stale: Bool = false, started: TimeInterval = -600
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: "build", title: title, mode: percent == nil ? .indeterminate : .determinate, percent: percent,
            status: status, state: state, stale: stale, startedAt: now.addingTimeInterval(started)
        )
    }

    @Test func runningLineHasTitleStatusPercentAndRemaining() {
        let line = LeoTaskText.summary(task(), etaAt: now.addingTimeInterval(250), now: now)
        #expect(line == "Xcode build · Compiling 412/980 · 62% · 4m")
    }

    @Test func missingPartsAreSkipped() {
        #expect(LeoTaskText.summary(task(status: nil), etaAt: nil, now: now) == "Xcode build · 62%")
    }

    @Test func indeterminateShowsElapsed() {
        let line = LeoTaskText.summary(task(percent: nil, status: nil, started: -125), etaAt: nil, now: now)
        #expect(line == "Xcode build · 2m")
    }

    @Test func staleDropsETAAndSaysStale() {
        let line = LeoTaskText.summary(task(stale: true), etaAt: now.addingTimeInterval(250), now: now)
        #expect(line == "Xcode build · Compiling 412/980 · 62% · stale")
    }

    @Test func failedLeadsWithFailed() {
        #expect(LeoTaskText.summary(task(state: .failed), etaAt: nil, now: now) == "Failed: Xcode build")
    }

    @Test func succeededAndCancelled() {
        #expect(LeoTaskText.summary(task(state: .succeeded), etaAt: nil, now: now) == "Done: Xcode build")
        #expect(LeoTaskText.summary(task(state: .cancelled), etaAt: nil, now: now) == "Cancelled: Xcode build")
    }

    @Test func percentRoundsAndClamps() {
        #expect(LeoTaskText.percent(61.6) == "62%")
        #expect(LeoTaskText.percent(0) == "0%")
    }

    @Test func durations() {
        #expect(LeoTaskText.duration(0) == "<1s")
        #expect(LeoTaskText.duration(45) == "45s")
        #expect(LeoTaskText.duration(59.6) == "1m")
        #expect(LeoTaskText.duration(60) == "1m")
        #expect(LeoTaskText.duration(250) == "4m")
        #expect(LeoTaskText.duration(3600) == "1h")
        #expect(LeoTaskText.duration(3900) == "1h 5m")
    }

    @Test func pastETAShowsNothing() {
        let line = LeoTaskText.summary(task(), etaAt: now.addingTimeInterval(-5), now: now)
        #expect(line == "Xcode build · Compiling 412/980 · 62%")
    }

    @Test func extraBadge() {
        #expect(LeoTaskText.extraBadge(0) == nil)
        #expect(LeoTaskText.extraBadge(3) == "+3")
    }
}
