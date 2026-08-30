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
        let board = BoardSession.snapshot(name: "w", host: LeoHost.localhostName, from: plan)
        #expect(board.cells.map(\.source) == [.agent(name: "a"), .pty])
    }

    @Test func snapshotPersistsHost() {
        let board = BoardSession.snapshot(name: "w", host: "dionysus", from: [])
        #expect(board.host == "dionysus")
    }
}

struct BoardSessionRestoreActionTests {
    private func board(_ cells: [BoardCell]) -> Board { Board(name: "w", cells: cells) }
    private func agent(_ name: String) -> Agent {
        Agent(name: name, template: "c", repo: "x/\(name)", workspace: "/w",
              status: .running, startedAt: "t", env: [:])
    }

    @Test func liveAgentBecomesALiveCell() {
        let actions = BoardSession.restoreActions(
            board: board([BoardCell(source: .agent(name: "a"))]),
            liveAgents: [agent("a")], alreadyOnBoard: [])
        #expect(actions == [.live(.agent(name: "a"))])
    }

    @Test func missingAgentWithSnapshotBecomesADeadCell() {
        let snap = AgentSnapshot(name: "gone", repo: "x/gone")
        let actions = BoardSession.restoreActions(
            board: board([BoardCell(source: .agent(name: "gone"), lastKnownAgent: snap)]),
            liveAgents: [], alreadyOnBoard: [])
        #expect(actions == [.dead(snap)])
    }

    @Test func missingAgentWithoutSnapshotIsSkipped() {
        // Regression: previously fell through to the live branch and attached
        // a surface to an agent that no longer exists.
        let actions = BoardSession.restoreActions(
            board: board([BoardCell(source: .agent(name: "gone"))]),
            liveAgents: [], alreadyOnBoard: [])
        #expect(actions == [.skip])
    }

    @Test func agentAlreadyOnBoardIsSkipped() {
        let actions = BoardSession.restoreActions(
            board: board([BoardCell(source: .agent(name: "a"))]),
            liveAgents: [agent("a")], alreadyOnBoard: ["a"])
        #expect(actions == [.skip])
    }

    @Test func duplicateDeadCellsAreCollapsed() {
        let snap = AgentSnapshot(name: "gone", repo: "x/gone")
        let actions = BoardSession.restoreActions(
            board: board([
                BoardCell(source: .agent(name: "gone"), lastKnownAgent: snap),
                BoardCell(source: .agent(name: "gone"), lastKnownAgent: snap)
            ]),
            liveAgents: [], alreadyOnBoard: [])
        #expect(actions == [.dead(snap), .skip])
    }
}

struct BoardSessionSnapshotMergeTests {
    @Test func prefersLiveRosterInfo() {
        let merged = BoardSession.snapshot(
            forAgent: "a",
            live: .init(repo: "x/a", template: "claude"),
            previous: AgentSnapshot(name: "a", repo: "old/a", template: "old"))
        #expect(merged == AgentSnapshot(name: "a", repo: "x/a", template: "claude"))
    }

    @Test func fallsBackToPersistedSnapshotWhenRosterIsUnavailable() {
        // Daemon offline / sidebar on another host: the roster has nothing, so
        // respawn-prefill data must survive from the previous save.
        let previous = AgentSnapshot(name: "a", repo: "x/a", template: "claude", branch: "main")
        #expect(BoardSession.snapshot(forAgent: "a", live: nil, previous: previous) == previous)
    }

    @Test func fillsEmptyLiveFieldsFromThePersistedSnapshot() {
        let merged = BoardSession.snapshot(
            forAgent: "a",
            live: .init(repo: "", template: nil),
            previous: AgentSnapshot(name: "a", repo: "x/a", template: "claude", branch: "main"))
        #expect(merged == AgentSnapshot(name: "a", repo: "x/a", template: "claude", branch: "main"))
    }

    @Test func keepsBranchFromThePersistedSnapshot() {
        let merged = BoardSession.snapshot(
            forAgent: "a",
            live: .init(repo: "x/a", template: "claude"),
            previous: AgentSnapshot(name: "a", repo: "x/a", template: "claude", branch: "feature"))
        #expect(merged.branch == "feature")
    }

    @Test func yieldsABareSnapshotWhenNothingIsKnown() {
        #expect(BoardSession.snapshot(forAgent: "a", live: nil, previous: nil)
                == AgentSnapshot(name: "a", repo: ""))
    }
}
