import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoTaskDetailTextTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func task(
        _ state: LeoAgentTask.State = .running, percent: Double? = 62, status: String? = nil, stale: Bool = false, updated: TimeInterval = 0, ended: TimeInterval? = nil
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: "x", title: "x", mode: percent == nil ? .indeterminate : .determinate, percent: percent, status: status, state: state,
            stale: stale, startedAt: t0, updatedAt: t0.addingTimeInterval(updated), endedAt: ended.map { t0.addingTimeInterval($0) }
        )
    }

    @Test func percentOnlyForDeterminateOrSucceeded() {
        #expect(LeoTaskDetailText.percent(Self.task()) == "62%")
        #expect(LeoTaskDetailText.percent(Self.task(percent: nil)) == nil)
        #expect(LeoTaskDetailText.percent(Self.task(.succeeded, percent: nil, ended: 5)) == "100%")
    }

    @Test func statusIsTheTasksOwnWordsThenTheState() {
        #expect(LeoTaskDetailText.status(Self.task(status: "Compiling"), now: Self.t0) == "Compiling")
        #expect(LeoTaskDetailText.status(Self.task(.failed, ended: 5), now: Self.t0) == "Failed")
        #expect(LeoTaskDetailText.status(Self.task(), now: Self.t0) == nil)
        #expect(LeoTaskDetailText.status(Self.task(stale: true, updated: 0), now: Self.t0.addingTimeInterval(18 * 60)) == "No update for 18m")
    }

    @Test func timingShowsElapsedAndEtaWhileRunningAndAgoOnceEnded() {
        let now = Self.t0.addingTimeInterval(252)
        #expect(LeoTaskDetailText.timing(Self.task(), etaAt: now.addingTimeInterval(180), now: now) == "4m · ETA ~3m")
        #expect(LeoTaskDetailText.timing(Self.task(), etaAt: nil, now: now) == "4m")
        #expect(LeoTaskDetailText.timing(Self.task(stale: true), etaAt: now.addingTimeInterval(180), now: now) == "4m")
        #expect(LeoTaskDetailText.timing(Self.task(.succeeded, ended: 100), etaAt: nil, now: now) == "2m ago")
    }

    @Test func headerCountsByState() {
        let tasks = [Self.task(), Self.task(), Self.task(.succeeded, ended: 1), Self.task(.failed, ended: 1)]
        #expect(LeoTaskDetailText.header(tasks) == "2 running · 1 failed · 1 done")
        #expect(LeoTaskDetailText.header([Self.task(), Self.task(), Self.task(.failed, ended: 1)]) == "2 running · 1 failed")
        #expect(LeoTaskDetailText.header([Self.task(.failed, ended: 1)]) == "1 failed")
        #expect(LeoTaskDetailText.header([Self.task(.succeeded, ended: 1)]) == "1 done")
    }
}
