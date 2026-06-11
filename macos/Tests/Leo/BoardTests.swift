import Testing
import Foundation
@testable import Ghostty

struct BoardTests {
    private func agentCell(_ name: String) -> BoardCell {
        BoardCell(source: .agent(name: name), lastKnownAgent: .init(name: name, repo: "x/\(name)"))
    }

    @Test func boardRoundTripsThroughCodable() throws {
        let board = Board(name: "work", cells: [agentCell("a"), BoardCell(source: .pty)])
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        #expect(decoded == board)
    }

    @Test func reconcileMarksMissingAgentsDead() {
        let board = Board(name: "work", cells: [agentCell("alive"), agentCell("gone"), BoardCell(source: .pty)])
        let live = [Agent(name: "alive", template: "coding", repo: "x/alive", workspace: "/w", status: .running, startedAt: "t", env: [:])]
        let result = board.reconciled(against: live)
        #expect(result.cells[0].liveness == .attached)
        #expect(result.cells[1].liveness == .dead)
        #expect(result.cells[2].liveness == .attached)
    }

    @Test func reconcileMarksStoppedAgentDead() {
        let board = Board(name: "w", cells: [agentCell("a")])
        let live = [Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .stopped, startedAt: "t", env: [:])]
        #expect(board.reconciled(against: live).cells[0].liveness == .dead)
    }
}
