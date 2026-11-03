import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

struct TaskPanelRenderPlanTests {
    static let row = TaskPanelRow(
        ref: AgentRef(daemonID: "d", name: "zeus"), displayName: "zeus", emoji: nil, task: .make("build", percent: 5), etaAt: nil
    )

    static func key(header: String = "Tasks 1", rows: [TaskPanelRow] = [row], collapsed: Bool = false, now: TimeInterval = 0) -> TaskPanelRenderKey {
        TaskPanelRenderKey(header: header, rows: rows, isCollapsed: collapsed, now: Date(timeIntervalSince1970: now))
    }

    @Test func theFirstRenderBuilds() {
        #expect(TaskPanelRenderPlan(previous: nil, next: Self.key()) == .rebuild)
    }

    @Test func anIdenticalRenderIsSkipped() {
        #expect(TaskPanelRenderPlan(previous: Self.key(), next: Self.key()) == .skip)
    }

    @Test func onlyTheClockMovingRelabelsInPlaceSoBarsKeepAnimating() {
        #expect(TaskPanelRenderPlan(previous: Self.key(now: 0), next: Self.key(now: 1)) == .relabel)
    }

    @Test(arguments: [
        TaskPanelRenderPlanTests.key(header: "Tasks 2"),
        TaskPanelRenderPlanTests.key(rows: []),
        TaskPanelRenderPlanTests.key(collapsed: true),
    ])
    func aRealChangeRebuilds(_ next: TaskPanelRenderKey) {
        #expect(TaskPanelRenderPlan(previous: Self.key(), next: next) == .rebuild)
    }

    @Test func aRealChangeWithAMovedClockStillRebuilds() {
        #expect(TaskPanelRenderPlan(previous: Self.key(now: 0), next: Self.key(header: "Tasks 2", now: 1)) == .rebuild)
    }

    /// The panel's rows for `zeus` with the given live action, through the real fleet.
    static func panelKey(action: String?, now: TimeInterval = 0) -> TaskPanelRenderKey {
        var state = Fleet.State(daemons: [.dionysus])
        var zeus = Agent(name: "zeus", status: .running, activity: .working)
        zeus.currentAction = action.flatMap { try? JSONDecoder().decode(LeoCurrentAction.self, from: Data(#"{"kind":"tool","detail":"\#($0)"}"#.utf8)) }
        zeus.tasks = [.make("build", percent: 5)]
        state.sessions[id: PairedDaemon.dionysus.id]?.agents = [zeus]
        return TaskPanelRenderKey(header: state.taskPanelHeader, rows: state.taskPanelRows, isCollapsed: false, now: Date(timeIntervalSince1970: now))
    }

    @Test func anAgentsLiveActionChangingDoesNotRestartThePanel() {
        #expect(TaskPanelRenderPlan(previous: Self.panelKey(action: "Edit a.swift"), next: Self.panelKey(action: "Bash swift test")) == .skip)
        #expect(TaskPanelRenderPlan(previous: Self.panelKey(action: "Edit a.swift", now: 0), next: Self.panelKey(action: "Bash swift test", now: 1)) == .relabel)
    }
}
