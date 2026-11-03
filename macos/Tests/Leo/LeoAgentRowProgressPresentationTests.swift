import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Row A: the thin task bar and the subtitle it replaces; attention wins.
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
        reason: LeoAttentionReason? = nil, error: String? = nil, now: Date? = nil
    ) -> LeoAgentRowPresentation {
        let row = LeoAgentRow(
            host: .local, name: "alpha", template: "claude", status: .running, activity: .idle, actionDetail: nil,
            attention: attention, attentionReason: reason, tasks: LeoRowTasks(tasks: tasks, etaAt: eta)
        )
        return LeoAgentRowPresentation(row: row, error: error, now: now)
    }

    @Test func determinateTaskShowsBarAndSummary() {
        let eta = Self.t0.addingTimeInterval(100 + 240)
        let p = presentation([Self.task()], eta: ["build": eta])
        #expect(p.progress?.kind == .determinate(62))
        #expect(p.progress?.fraction == 0.62)
        #expect(p.detail == .progress("Xcode build · Compiling · 62% · 4m"))
        #expect(p.hasSecondLine)
    }

    @Test func indeterminateTaskGetsAnAnimatedBar() {
        let p = presentation([Self.task(mode: .indeterminate, percent: nil, status: nil)], now: Self.t0.addingTimeInterval(125))
        #expect(p.progress?.kind == .indeterminate)
        #expect(p.progress?.fraction == nil)
        #expect(p.detail == .progress("Xcode build · 2m"))
    }

    @Test func staleTaskIsDimmedAndSaysStale() {
        let p = presentation([Self.task(stale: true)])
        #expect(p.progress?.kind == .stale(62))
        #expect(p.detail == .progress("Xcode build · Compiling · 62% · stale"))
    }

    @Test func failedTaskIsRedAndNamed() {
        let p = presentation([Self.task(state: .failed)])
        #expect(p.progress?.kind == .failed)
        #expect(p.detail == .progress("Failed: Xcode build"))
        #expect(p.detailInk == .tint(.red))
    }

    @Test func extraTasksAddABadge() {
        let p = presentation([Self.task(), Self.task("lint", title: "Lint", updated: 50), Self.task("docs", title: "Docs", updated: 40)])
        #expect(p.progress?.extraBadge == "+2")
        #expect(presentation([Self.task()]).progress?.extraBadge == nil)
    }

    @Test func needsInputAttentionHidesTheBarAndKeepsTheReason() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm -rf build")
        let p = presentation([Self.task()], attention: .needsInput, reason: reason)
        #expect(p.progress == nil)
        #expect(p.detail == .attention("Bash: rm -rf build"))
    }

    @Test func needsInputWithoutAReasonStillHidesTheBar() {
        let p = presentation([Self.task()], attention: .needsInput)
        #expect(p.progress == nil)
        if case .progress = p.detail { Issue.record("subtitle must not show the task") }
    }

    @Test func workingAttentionDoesNotHideTheBar() {
        #expect(presentation([Self.task()], attention: .working).progress != nil)
    }

    @Test func errorAndWarningOutrankTheSubtitleButNotTheBar() {
        let p = presentation([Self.task()], error: "Start failed")
        #expect(p.detail == .error("Start failed"))
        #expect(p.progress?.kind == .determinate(62))
    }

    @Test func noTasksChangesNothing() {
        let p = presentation([])
        #expect(p.progress == nil)
        #expect(p.detail == .fallback("claude"))
    }

    @Test func finishedTasksShowDoneAndCancelled() {
        #expect(presentation([Self.task(state: .succeeded)]).detail == .progress("Done: Xcode build"))
        #expect(presentation([Self.task(state: .succeeded)]).progress?.kind == .succeeded)
        #expect(presentation([Self.task(state: .cancelled)]).progress?.kind == .cancelled)
    }

    @Test func failedTaskIsTheRowsPrimaryEvenAmongRunning() {
        let p = presentation([Self.task("a", title: "Running", updated: 200), Self.task("b", title: "Broke", state: .failed, updated: 10)])
        #expect(p.progress?.kind == .failed)
        #expect(p.progress?.extraBadge == "+1")
    }
}
