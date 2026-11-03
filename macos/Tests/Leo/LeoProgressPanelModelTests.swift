import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Chat panel B: which tasks across all agents the card lists, in what order.
struct LeoProgressPanelModelTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func task(_ id: String, percent: Double? = 50, state: LeoAgentTask.State = .running, updated: TimeInterval = 0) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: id, mode: percent == nil ? .indeterminate : .determinate, percent: percent, state: state,
            startedAt: t0, updatedAt: t0.addingTimeInterval(updated), endedAt: state == .running ? nil : t0
        )
    }

    private static func row(_ name: String, host: LeoHostID = .local, _ tasks: [LeoAgentTask], emoji: String? = nil) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: nil, status: .running, activity: .idle, actionDetail: nil,
            appearance: emoji.map { LeoAgentAppearance(emoji: $0, color: nil, emojiSource: .manual, colorSource: nil) },
            tasks: LeoRowTasks(tasks: tasks, etaAt: [:])
        )
    }

    @Test func listsRunningAndFailedAcrossAgentsAndHidesEndedOnes() {
        let model = LeoProgressPanelModel(rows: [
            Self.row("a", [Self.task("run"), Self.task("done", state: .succeeded), Self.task("gone", state: .cancelled)]),
            Self.row("b", host: .remote("mars"), [Self.task("bad", state: .failed)]),
            Self.row("c", []),
        ])
        #expect(model.entries.map(\.task.id) == ["bad", "run"])
        #expect(model.entries.map(\.agent.host) == [.remote("mars"), .local])
    }

    @Test func failedFirstThenNewestUpdateAndStable() {
        let model = LeoProgressPanelModel(rows: [
            Self.row("a", [Self.task("old", updated: 1), Self.task("new", updated: 9), Self.task("bad", state: .failed, updated: 0)]),
            Self.row("b", [Self.task("tie", updated: 9)]),
        ])
        #expect(model.entries.map(\.task.id) == ["bad", "new", "tie", "old"])
    }

    @Test func emptyWhenNothingIsRunningOrFailed() {
        #expect(LeoProgressPanelModel(rows: [Self.row("a", [Self.task("done", state: .succeeded)])]).isEmpty)
        #expect(LeoProgressPanelModel(rows: []).isEmpty)
    }

    @Test func collapsedTitleCountsTasksAndAveragesDeterminatePercent() {
        let model = LeoProgressPanelModel(rows: [
            Self.row("a", [Self.task("x", percent: 80), Self.task("y", percent: 44), Self.task("z", percent: nil)]),
        ])
        #expect(model.collapsedTitle == "Tasks 3 · 62%")
        #expect(LeoProgressPanelModel(rows: [Self.row("a", [Self.task("z", percent: nil)])]).collapsedTitle == "Tasks 1")
    }

    @Test func entriesCarryTheAgentsEmojiAndName() {
        let model = LeoProgressPanelModel(rows: [Self.row("alpha", [Self.task("x")], emoji: "🏛️")])
        #expect(model.entries.first?.emoji == "🏛️")
        #expect(model.entries.first?.displayName == "alpha")
    }

    @Test func entryIdsStayUniqueForSameNamedAgentsOnDifferentHosts() {
        let model = LeoProgressPanelModel(rows: [
            Self.row("a", host: .local, [Self.task("x")]),
            Self.row("a", host: .remote(LeoHostID.local.displayName), [Self.task("x")]),
        ])
        #expect(Set(model.entries.map(\.id)).count == 2)
    }
}
