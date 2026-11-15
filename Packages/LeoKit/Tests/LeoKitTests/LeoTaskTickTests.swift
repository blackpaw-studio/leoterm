import Foundation
import Testing

@testable import LeoKit

struct LeoTaskTickTests {
    /// On both the 1 s and 15 s tick grids, so expected tick times are exact.
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_005)

    private func task(
        mode: LeoAgentTask.Mode = .indeterminate, state: LeoAgentTask.State = .running, stale: Bool = false,
        started: TimeInterval, updated: TimeInterval? = nil, ended: TimeInterval? = nil
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: "t", title: "Build", mode: mode, percent: mode == .determinate ? 50 : nil, state: state, stale: stale,
            startedAt: now.addingTimeInterval(started), updatedAt: updated.map { now.addingTimeInterval($0) },
            endedAt: ended.map { now.addingTimeInterval($0) }
        )
    }

    private func next(_ tasks: [LeoAgentTask], etaAt: [String: Date] = [:], after date: Date? = nil) -> TimeInterval {
        LeoTaskTick.next(after: date ?? now, tasks: tasks, etaAt: etaAt).timeIntervalSince(date ?? now)
    }

    @Test func elapsedShowingSecondsTicksEverySecond() {
        #expect(next([task(started: -20)]) == 1)
    }

    @Test func elapsedShowingMinutesTicksCoarsely() {
        #expect(next([task(started: -300)]) == LeoTaskTick.coarse)
    }

    @Test func secondsTicksLandOnWholeSeconds() {
        let date = now.addingTimeInterval(0.4)
        let tick = LeoTaskTick.next(after: date, tasks: [task(started: -20)], etaAt: [:])
        #expect(tick == now.addingTimeInterval(1))
    }

    @Test func remainingTimeUnderAMinuteTicksEverySecond() {
        let running = task(mode: .determinate, started: -300)
        #expect(next([running], etaAt: ["t": now.addingTimeInterval(40)]) == 1)
    }

    @Test func remainingTimeAboveAMinuteSwitchesToSecondsWhenItCrossesOne() {
        let running = task(mode: .determinate, started: -300)
        let wait = next([running], etaAt: ["t": now.addingTimeInterval(70)])
        #expect(wait > 0 && wait <= 10.5)
    }

    @Test func staleAgeUnderAMinuteTicksEverySecond() {
        #expect(next([task(stale: true, started: -300, updated: -30)]) == 1)
    }

    @Test func recentlyEndedTaskTicksEverySecondThenCoarsely() {
        #expect(next([task(state: .succeeded, started: -300, ended: -10)]) == 1)
        #expect(next([task(state: .succeeded, started: -900, ended: -600)]) == LeoTaskTick.coarse)
    }

    @Test func noTasksTickCoarsely() {
        #expect(next([]) == LeoTaskTick.coarse)
    }

    @Test func anyTaskShowingSecondsWins() {
        #expect(next([task(started: -600), task(started: -5)]) == 1)
    }
}
