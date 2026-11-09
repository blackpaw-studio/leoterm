import Foundation
import Testing

@testable import LeoKit

struct LeoTaskRowPresentationTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func task(
        _ id: String, title: String? = nil, _ state: LeoAgentTask.State = .running, percent: Double? = nil,
        mode: LeoAgentTask.Mode? = nil, stale: Bool = false, updated: TimeInterval = 9_990
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: title ?? id, mode: mode ?? (percent == nil ? .indeterminate : .determinate), percent: percent,
            state: state, stale: stale, startedAt: Date(timeIntervalSince1970: 9_000),
            updatedAt: Date(timeIntervalSince1970: updated),
            endedAt: state == .running ? nil : Date(timeIntervalSince1970: updated)
        )
    }

    private func summary(_ tasks: [LeoAgentTask], agentIsInError: Bool = false) -> LeoTaskRowSummary? {
        LeoTaskRowPresentation.summary(tasks, etaAt: [:], agentIsInError: agentIsInError, now: now)
    }

    @Test func noTasksHasNoSummary() {
        #expect(summary([]) == nil)
    }

    @Test func liveDeterminateShowsPieAndTitle() {
        let s = summary([task("build", title: "Build Leo.app", percent: 62)])
        #expect(s?.indicator == .progress(fraction: 0.62))
        #expect(s?.detail == "Build Leo.app")
        #expect(s?.spokenValue == "Build Leo.app, 62 percent")
    }

    @Test func mixedLiveTasksAverageOnlyTheDeterminateOnes() {
        let s = summary([task("a", percent: 20), task("b", percent: 60), task("c")])
        #expect(s?.indicator == .progress(fraction: 0.4))
    }

    @Test func onlyIndeterminateTasksShowTheSpinner() {
        let s = summary([task("a"), task("b")])
        #expect(s?.indicator == .progress(fraction: nil))
        #expect(s?.spokenValue == "In progress")
    }

    @Test func determinateTaskWithoutPercentCountsAsIndeterminate() {
        let s = summary([task("a", mode: .determinate)])
        #expect(s?.indicator == .progress(fraction: nil))
    }

    @Test func staleOnlyShowsMutedPieAndStaleText() {
        let s = summary([task("sweep", title: "Sweep", percent: 30, stale: true, updated: 9_880)])
        #expect(s?.indicator == .stalled(fraction: 0.3))
        #expect(s?.detail == "Sweep · no update for 2m")
        #expect(s?.spokenValue == "Stalled")
    }

    @Test func staleWithoutPercentShowsEmptyMutedPie() {
        let s = summary([task("a", stale: true)])
        #expect(s?.indicator == .stalled(fraction: nil))
    }

    @Test func staleUsesTheMostRecentlyUpdatedStaleTask() {
        let s = summary([task("old", percent: 10, stale: true, updated: 100), task("new", percent: 70, stale: true, updated: 200)])
        #expect(s?.indicator == .stalled(fraction: 0.7))
    }

    @Test func failedTaskShowsGlyphWhenAgentIsNotInError() {
        let s = summary([task("t", title: "Deploy", .failed)])
        #expect(s?.indicator == .failed)
        #expect(s?.detail == "Failed: Deploy")
        #expect(s?.spokenValue == "Failed")
    }

    @Test func failedTaskYieldsToAgentErrorState() {
        let s = summary([task("t", title: "Deploy", .failed)], agentIsInError: true)
        #expect(s?.indicator == nil)
        #expect(s?.detail == "Failed: Deploy")
    }

    @Test func liveTaskBeatsFailedGlyph() {
        let s = summary([task("bad", .failed), task("run", percent: 50)])
        #expect(s?.indicator == .progress(fraction: 0.5))
        #expect(s?.detail == "Failed: bad")
    }

    @Test func succeededAndCancelledFallThrough() {
        #expect(summary([task("a", .succeeded)])?.indicator == nil)
        #expect(summary([task("a", .succeeded)])?.detail == nil)
        #expect(summary([task("a", .cancelled)])?.detail == nil)
        #expect(summary([task("a", .cancelled)])?.spokenValue == nil)
    }

    @Test func severalRunningCountsOtherRunningTasksOnly() {
        let tasks = [
            task("a", title: "Screenshot sweep", percent: 40, updated: 9_995), task("b", percent: 50, updated: 9_990),
            task("c", stale: true, updated: 100), task("done", .succeeded),
        ]
        let s = summary(tasks)
        #expect(s?.detail == "Screenshot sweep and 2 more")
        #expect(s?.spokenValue == "Screenshot sweep and 2 more, 45 percent")
    }

    @Test func tooltipIsTheFullSummaryPlusOthers() {
        let one = summary([task("a", title: "Build", percent: 62)])
        #expect(one?.tooltip == LeoTaskText.summary(task("a", title: "Build", percent: 62), etaAt: nil, now: now))
        let two = summary([task("a", title: "Build", percent: 62, updated: 9_995), task("b")])
        #expect(two?.tooltip.hasSuffix(", 1 more") == true)
    }

    @Test func tooltipUsesTheSuppliedETA() {
        let eta = now.addingTimeInterval(240)
        let s = LeoTaskRowPresentation.summary(
            [task("a", title: "Build", percent: 62)], etaAt: ["a": eta], agentIsInError: false, now: now)
        #expect(s?.tooltip == "Build · 62% · 4m")
    }
}
