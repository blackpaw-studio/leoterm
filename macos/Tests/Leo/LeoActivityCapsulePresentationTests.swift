import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The toolbar activity capsule: what it shows, how it degrades, what the popover lists. Pure.
struct LeoActivityCapsulePresentationTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func task(
        _ id: String, title: String? = nil, percent: Double? = 50, state: LeoAgentTask.State = .running,
        status: String? = nil, updated: TimeInterval = 0
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: title ?? id, mode: percent == nil ? .indeterminate : .determinate, percent: percent, status: status,
            state: state, startedAt: t0, updatedAt: t0.addingTimeInterval(updated), endedAt: state == .running ? nil : t0
        )
    }

    /// 10 pt per character, so widths are exact in tests.
    private static let measure: (String, LeoActivityCapsulePresentation.TextRole) -> CGFloat = { text, _ in CGFloat(text.count) * 10 }

    private static func make(_ tasks: [LeoAgentTask], eta: [String: Date] = [:], width: CGFloat = 500) -> LeoActivityCapsulePresentation {
        LeoActivityCapsulePresentation(
            tasks: LeoRowTasks(tasks: tasks, etaAt: eta), now: t0.addingTimeInterval(60), availableWidth: width, measure: measure
        )
    }

    private static func idle(_ state: LeoActivityCapsulePresentation.AgentState, width: CGFloat = 500) -> LeoActivityCapsulePresentation {
        LeoActivityCapsulePresentation(tasks: .none, state: state, now: t0, availableWidth: width, measure: measure)
    }

    // MARK: Always shown (spec amendment 2026-11-04)

    @Test func anAgentWithNoTasksStillShowsTheCapsule() {
        let capsule = Self.make([])
        #expect(capsule.isVisible)
        #expect(capsule.kind == .agentState)
        #expect(capsule.isEnabled)
        #expect(capsule.width == 500)
    }

    @Test func theStateTextFollowsTheAttentionState() {
        typealias State = LeoActivityCapsulePresentation.AgentState
        #expect(State(attention: .needsInput, isWorking: false).text == "Needs you")
        #expect(State(attention: .errored, isWorking: false).text == "Errored")
        #expect(State(attention: .working, isWorking: false).text == "Working")
        #expect(State(attention: nil, isWorking: true).text == "Working")
        #expect(State(attention: .finished, isWorking: false).text == "Idle")
        #expect(State(attention: nil, isWorking: false).text == "Idle")
    }

    @Test func needsYouAndErrorOutrankWorking() {
        typealias State = LeoActivityCapsulePresentation.AgentState
        #expect(State(attention: .needsInput, isWorking: true) == .needsYou)
        #expect(State(attention: .errored, isWorking: true) == .errored)
    }

    @Test func noTasksShowsTheStateAsPlainTextWithATintedDotAndNoBarOrBadge() {
        for state in [.working, .idle, .needsYou, .errored] as [LeoActivityCapsulePresentation.AgentState] {
            let capsule = Self.idle(state)
            #expect(capsule.title == state.text)
            #expect(capsule.statusText == nil)
            #expect(capsule.glyph == .dot(state))
            #expect(capsule.bar == nil)
            #expect(capsule.badge == nil)
            #expect(capsule.variant == .full)
        }
    }

    @Test func noTasksReadsAsTheStateInVoiceOver() {
        #expect(Self.idle(.needsYou).accessibilityLabel == "Needs you, no tasks")
    }

    @Test func noTasksOpensAPopoverWithANoTasksEmptyState() {
        let capsule = Self.idle(.idle)
        #expect(capsule.popover.rows.isEmpty)
        #expect(capsule.popover.emptyMessage == "No tasks")
        #expect(Self.make([Self.task("a")]).popover.emptyMessage == nil)
    }

    @Test func aTerminalRowOrTheStartScreenShowsNoAgentAndIsDisabled() {
        let capsule = LeoActivityCapsulePresentation.noAgent(availableWidth: 500)
        #expect(capsule.isVisible)
        #expect(capsule.kind == .noAgent)
        #expect(capsule.title == "No agent")
        #expect(!capsule.isEnabled)
        #expect(capsule.glyph == .dot(nil))
        #expect(capsule.bar == nil && capsule.badge == nil)
        #expect(capsule.popover.rows.isEmpty)
    }

    @Test func picksPrimaryTask() {
        let capsule = Self.make([Self.task("run", updated: 9), Self.task("bad", state: .failed), Self.task("done", state: .succeeded)])
        #expect(capsule.isVisible)
        #expect(capsule.title == "bad")
        #expect(capsule.glyph == .failed)
        #expect(capsule.bar == .failed)
    }

    @Test func glyphFollowsPrimaryState() {
        #expect(Self.make([Self.task("a")]).glyph == .spinner)
        #expect(Self.make([Self.task("a", state: .succeeded)]).glyph == .succeeded)
        #expect(Self.make([Self.task("a", state: .cancelled)]).glyph == .cancelled)
    }

    @Test func barIsDeterminateOrIndeterminate() {
        #expect(Self.make([Self.task("a", percent: 40)]).bar == .determinate(40))
        #expect(Self.make([Self.task("a", percent: nil)]).bar == .indeterminate)
    }

    @Test func statusPrefersTaskOwnWordsThenTrailing() {
        #expect(Self.make([Self.task("a", status: "Compiling")]).statusText == "Compiling")
        let eta = Self.t0.addingTimeInterval(60 + 120)
        #expect(Self.make([Self.task("a", percent: 50)], eta: ["a": eta]).statusText == "50% · ~2m")
        #expect(Self.make([Self.task("a", percent: nil)]).statusText == "1m")
    }

    @Test func endedWithoutStatusReadsDone() {
        #expect(Self.make([Self.task("a", state: .succeeded)]).statusText == "Succeeded")
    }

    @Test func badgeCountsFromTwoTasksAndTurnsRedOnFailure() {
        #expect(Self.make([Self.task("a")]).badge == nil)
        #expect(Self.make([Self.task("a"), Self.task("b")]).badge == .init(count: 2, isRed: false))
        #expect(Self.make([Self.task("a"), Self.task("b"), Self.task("c", state: .failed)]).badge == .init(count: 3, isRed: true))
    }

    @Test func fullVariantWhenEverythingFits() {
        let capsule = Self.make([Self.task("build", status: "ok")], width: 500)
        #expect(capsule.variant == .full)
        #expect(capsule.width == 500)
    }

    @Test func statusDropsFirstWhenNarrow() {
        let task = Self.task("build", status: "compiling")
        #expect(Self.make([task], width: 500).variant == .full)
        // Chrome + "build" fits, chrome + "build" + "compiling" does not.
        let narrow = LeoActivityCapsulePresentation.chromeWidth(badge: false) + 50 + 20
        let capsule = Self.make([task], width: narrow)
        #expect(capsule.variant == .titleOnly)
        #expect(capsule.title == "build")
    }

    @Test func titleOnlyStaysEvenWhenTitleCannotFit() {
        let capsule = Self.make([Self.task("a-very-long-task-title")], width: 120)
        #expect(capsule.variant == .titleOnly)
        #expect(capsule.width == 120)
    }

    @Test func widthCapsAtFiveHundred() {
        #expect(Self.make([Self.task("a")], width: 900).width == 500)
    }

    @Test func accessibilityLabelPluralizes() {
        #expect(Self.make([Self.task("Build", status: "Compiling")]).accessibilityLabel == "Build, Compiling, 1 task")
        #expect(Self.make([Self.task("Build", status: "Compiling"), Self.task("x")]).accessibilityLabel == "Build, Compiling, 2 tasks")
    }

    @Test func popoverSummaryOmitsFailedAtZero() {
        #expect(Self.make([Self.task("a"), Self.task("b")]).popover.summary == "2")
        let mixed = Self.make([Self.task("a"), Self.task("b"), Self.task("c", state: .failed)])
        #expect(mixed.popover.summary == "3 · 1 failed")
    }

    @Test func popoverRowsFollowOrderedWithTileAndDismiss() {
        let capsule = Self.make([
            Self.task("done", state: .succeeded), Self.task("run", status: "Working"), Self.task("bad", state: .failed),
            Self.task("cx", state: .cancelled),
        ])
        let rows = capsule.popover.rows
        #expect(rows.map(\.id) == ["bad", "run", "cx", "done"])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["bad"]?.tile == .failed && byID["bad"]?.canDismiss == true)
        #expect(byID["run"]?.tile == .running && byID["run"]?.canDismiss == false)
        #expect(byID["cx"]?.tile == .cancelled && byID["done"]?.tile == .succeeded)
        #expect(byID["run"]?.statusLine == "Working")
        #expect(byID["done"]?.statusLine == "Succeeded")
        #expect(byID["run"]?.bar == .determinate(50))
    }

    @Test func popoverStatusLineFallsBackToTiming() {
        let capsule = Self.make([Self.task("a", percent: nil)])
        #expect(capsule.popover.rows.first?.statusLine == "1m")
    }
}
