import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The row's trailing task indicator and the task text on line 2; attention wins.
struct LeoAgentRowProgressPresentationTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func task(
        _ id: String = "build", title: String = "Xcode build", mode: LeoAgentTask.Mode = .determinate, percent: Double? = 62,
        status: String? = "Compiling", state: LeoAgentTask.State = .running, stale: Bool = false, updated: TimeInterval = 100
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: title, mode: mode, percent: percent, status: status, state: state, stale: stale,
            startedAt: t0, updatedAt: t0.addingTimeInterval(updated), endedAt: state == .running ? nil : t0.addingTimeInterval(updated)
        )
    }

    private func presentation(
        _ tasks: [LeoAgentTask], eta: [String: Date] = [:], attention: LeoAttentionBadge? = nil,
        reason: LeoAttentionReason? = nil, error: String? = nil, now: Date? = nil, activity: LeoActivity = .idle
    ) -> LeoAgentRowPresentation {
        let row = LeoAgentRow(
            host: .local, name: "alpha", template: "claude", status: .running, activity: activity, actionDetail: nil,
            attention: attention, attentionReason: reason, tasks: LeoRowTasks(tasks: tasks, etaAt: eta)
        )
        return LeoAgentRowPresentation(row: row, error: error, now: now)
    }

    /// B-395: a move's stage is the daemon's own word, below an error and above task text.
    @Test func aRunningMovesStageShowsOnTheDetailLine() {
        let row = LeoAgentRow(host: .local, name: "alpha", template: "claude", status: .running, activity: .idle, actionDetail: nil)
        #expect(LeoAgentRowPresentation(row: row, error: nil, moveStage: "rsync-workspace").detail == .progress("rsync-workspace\u{2026}"))
        #expect(LeoAgentRowPresentation(row: row, error: "boom", moveStage: "rsync-workspace").detail == .error("boom"))
    }

    @Test func determinateTaskShowsPieAndTitleOnly() {
        let eta = Self.t0.addingTimeInterval(100 + 240)
        let p = presentation([Self.task()], eta: ["build": eta])
        #expect(p.task?.indicator == .progress(fraction: 0.62))
        #expect(p.detail == .progress("Xcode build"))
        #expect(p.task?.tooltip == "Xcode build · Compiling · 62% · 4m")
        #expect(p.hasSecondLine)
    }

    @Test func indeterminateTaskHasNoTrailingIndicator() {
        let p = presentation([Self.task(mode: .indeterminate, percent: nil, status: nil)], now: Self.t0.addingTimeInterval(125))
        #expect(p.taskIndicator == nil)
        #expect(p.detail == .progress("Xcode build"))
        #expect(p.task?.spokenValue == "In progress")
    }

    @Test func staleTaskIsMutedAndSaysHowLongAgo() {
        let p = presentation([Self.task(stale: true)], now: Self.t0.addingTimeInterval(100 + 1_200))
        #expect(p.task?.indicator == .stalled(fraction: 0.62))
        #expect(p.detail == .progress("Xcode build · no update for 20m"))
    }

    @Test func failedTaskIsGlyphRedAndNamed() {
        let p = presentation([Self.task(state: .failed)])
        #expect(p.task?.indicator == .failed)
        #expect(p.detail == .progress("Failed: Xcode build"))
        #expect(p.detailInk == .tint(.red))
    }

    @Test func failedTaskOnAnErroredAgentHasNoGlyphButKeepsTheText() {
        let p = presentation([Self.task(state: .failed)], attention: .errored)
        #expect(p.task?.indicator == nil)
        #expect(p.detail == .progress("Failed: Xcode build"))
    }

    @Test func severalRunningTasksNameTheOthersInTheText() {
        let p = presentation([Self.task(), Self.task("lint", title: "Lint", updated: 50), Self.task("docs", title: "Docs", updated: 40)])
        #expect(p.detail == .progress("Xcode build and 2 more"))
    }

    @Test func needsInputAttentionHidesTheTaskAndKeepsTheReason() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm -rf build")
        let p = presentation([Self.task()], attention: .needsInput, reason: reason)
        #expect(p.task == nil)
        #expect(p.detail == .attention("Bash: rm -rf build"))
    }

    @Test func needsInputWithoutAReasonStillHidesTheTask() {
        let p = presentation([Self.task()], attention: .needsInput)
        #expect(p.task == nil)
        if case .progress = p.detail { Issue.record("subtitle must not show the task") }
    }

    @Test func workingAttentionDoesNotHideTheTask() {
        #expect(presentation([Self.task()], attention: .working).task != nil)
    }

    @Test func errorAndWarningOutrankTheTaskTextButNotTheIndicator() {
        let p = presentation([Self.task()], error: "Start failed")
        #expect(p.detail == .error("Start failed"))
        #expect(p.task?.indicator == .progress(fraction: 0.62))
    }

    @Test func noTasksChangesNothing() {
        let p = presentation([])
        #expect(p.task == nil)
        #expect(p.detail == .fallback("claude"))
    }

    @Test func finishedTasksFallThroughToTheNextDetail() {
        let p = presentation([Self.task(state: .succeeded)])
        #expect(p.detail == .fallback("claude"))
        #expect(p.task?.indicator == nil)
        #expect(p.hasSecondLine)
        #expect(presentation([Self.task(state: .cancelled)]).detail == .fallback("claude"))
    }

    @Test func failedTaskIsTheRowsPrimaryEvenAmongRunning() {
        let p = presentation([Self.task("a", title: "Running", updated: 200), Self.task("b", title: "Broke", state: .failed, updated: 10)])
        #expect(p.detail == .progress("Failed: Broke"))
        #expect(p.task?.indicator == .progress(fraction: 0.62))
    }

    private static let everyTaskSet: [[LeoAgentTask]] = [
        [],
        [Self.task()],
        [Self.task(mode: .indeterminate, percent: nil)],
        [Self.task(stale: true)],
        [Self.task(state: .failed)],
        [Self.task(state: .succeeded)],
        [Self.task("a", title: "Broke", state: .failed, updated: 10), Self.task("b", updated: 200)],
        [Self.task("a"), Self.task("b", mode: .indeterminate, percent: nil)],
    ]

    @Test func workingSymbolRotatesWhateverTheTask() {
        for tasks in Self.everyTaskSet {
            let p = presentation(tasks, activity: .working)
            #expect(p.state.rotates)
            #expect(p.symbolRotates, "indicator \(String(describing: p.task?.indicator))")
        }
    }

    @Test func stillIndicatorsStay() {
        #expect(presentation([Self.task()]).taskIndicator == .progress(fraction: 0.62))
        #expect(presentation([Self.task(stale: true)]).taskIndicator == .stalled(fraction: 0.62))
        #expect(presentation([Self.task(state: .failed)]).taskIndicator == .failed)
        let mixed = presentation([Self.task("a", percent: 40), Self.task("b", mode: .indeterminate, percent: nil)])
        #expect(mixed.taskIndicator == mixed.task?.indicator)
        #expect(mixed.taskIndicator != nil)
    }

    /// Permanent invariant: the row never draws a moving task indicator.
    @Test func noRowEverDrawsAMovingIndicator() {
        for tasks in Self.everyTaskSet {
            #expect(presentation(tasks, activity: .working).taskIndicator != .progress(fraction: nil))
        }
    }

    /// B-390 / D-766: the spinning symbol opens Tasks for every task set
    /// (including the indeterminate one, which draws no trailing indicator),
    /// and a row without a task leaves it a plain symbol. Line 2 never opens
    /// Tasks: the presentation has no such route, so a click there selects.
    @Test func symbolOpensTasksOnlyWithATask() {
        // The same condition as the row's "Show Tasks" VoiceOver action.
        for (index, tasks) in Self.everyTaskSet.enumerated() where index != 0 {
            #expect(presentation(tasks, activity: .working).symbolOpensTasks)
        }
        #expect(!presentation([], activity: .working).symbolOpensTasks)
    }

    /// B-382: the context menu's "Show Tasks" is present exactly when the row
    /// has a task (the VoiceOver action's condition), so a mouse user reaches
    /// Tasks even when an error takes line 2 or the task has no indicator.
    @Test func contextMenuOffersShowTasksOnlyWithATask() {
        func showTasks(_ tasks: [LeoAgentTask], error: String? = nil) -> Bool {
            let p = presentation(tasks, error: error)
            return LeoRowActionAvailability(status: .running, isPending: false, hasTasks: p.task != nil).showTasks
        }
        for (index, tasks) in Self.everyTaskSet.enumerated() where index != 0 {
            #expect(showTasks(tasks))
            #expect(showTasks(tasks, error: "boom"))
        }
        #expect(!showTasks([]))
        #expect(!LeoRowActionAvailability(status: .running, isPending: false).showTasks)
    }

    @Test func workingSymbolSpinsWithNoIndicator() {
        #expect(presentation([], activity: .working).symbolRotates)
        #expect(presentation([Self.task(state: .succeeded)], activity: .working).symbolRotates)
    }
}
