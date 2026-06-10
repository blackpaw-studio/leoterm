import Testing
import Foundation
@testable import Ghostty

struct BoardSessionTests {
    @Test func restorePlanAttachesLiveAndDeadensMissing() {
        let board = Board(name: "w", cells: [
            BoardCell(source: .agent(name: "alive"), lastKnownAgent: .init(name: "alive", repo: "x/alive")),
            BoardCell(source: .agent(name: "gone"), lastKnownAgent: .init(name: "gone", repo: "x/gone")),
            BoardCell(source: .pty)
        ])
        let live = [Agent(name: "alive", template: "c", repo: "x/alive", workspace: "/w", status: .running, startedAt: "t", env: [:])]
        let plan = BoardSession.restorePlan(board: board, liveAgents: live)
        #expect(plan.filter { $0.isDead }.count == 1)
        #expect(plan.filter { !$0.isDead }.map(\.source) == [.agent(name: "alive"), .pty])
    }

    @Test func snapshotCapturesSourcesInOrder() {
        let plan = [
            BoardSession.PlannedCell(source: .agent(name: "a"), snapshot: .init(name: "a", repo: "x/a"), isDead: false),
            BoardSession.PlannedCell(source: .pty, snapshot: nil, isDead: false)
        ]
        let board = BoardSession.snapshot(name: "w", from: plan)
        #expect(board.cells.map(\.source) == [.agent(name: "a"), .pty])
    }
}
