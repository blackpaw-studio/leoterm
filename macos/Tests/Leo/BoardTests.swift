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

    @Test func boardDefaultsToLocalhostHost() {
        let board = Board(name: "w", cells: [])
        #expect(board.host == "localhost")
    }

    @Test func boardDecodesMissingHostAsLocalhost() throws {
        // Legacy persisted board JSON predates the host field.
        let json = Data("""
        {"id":"\(UUID().uuidString)","name":"legacy","cells":[]}
        """.utf8)
        let board = try JSONDecoder().decode(Board.self, from: json)
        #expect(board.host == "localhost")
    }

    @Test func boardRoundTripsCustomHost() throws {
        let board = Board(name: "remote", host: "dionysus", cells: [agentCell("a")])
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        #expect(decoded == board)
        #expect(decoded.host == "dionysus")
    }

    // MARK: - pinnedRowHeights Codable tests

    @Test func boardRoundTripsPinnedRowHeights() throws {
        let pins: [Int: CGFloat] = [0: 120.0, 2: 200.0]
        let board = Board(name: "pinned", cells: [agentCell("a")], pinnedRowHeights: pins)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        #expect(decoded == board)
        #expect(decoded.pinnedRowHeights == pins)
    }

    @Test func boardRoundTripsNoPinnedRowHeights() throws {
        let board = Board(name: "unpinned", cells: [agentCell("b")])
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        #expect(decoded == board)
        #expect(decoded.pinnedRowHeights == nil)
    }

    @Test func boardDecodesLegacyJSONWithoutPinnedRowHeights() throws {
        // Legacy boards.json produced before the pinnedRowHeights field was added
        // must decode cleanly with nil pins.
        let json = Data("""
        {"cells":[],"host":"localhost","id":"\(UUID().uuidString)","name":"legacy"}
        """.utf8)
        let board = try JSONDecoder().decode(Board.self, from: json)
        #expect(board.pinnedRowHeights == nil)
    }

    @Test func agentSnapshotRoundTripsTemplateAndBranch() throws {
        let snap = AgentSnapshot(name: "a", repo: "x/a", template: "coding", branch: "main")
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(AgentSnapshot.self, from: data)
        #expect(decoded == snap)
        #expect(decoded.template == "coding")
        #expect(decoded.branch == "main")
    }

    @Test func agentSnapshotDecodesLegacyWithoutTemplateOrBranch() throws {
        // Legacy snapshots without template/branch must decode cleanly.
        let json = Data(#"{"name":"a","repo":"x/a"}"#.utf8)
        let snap = try JSONDecoder().decode(AgentSnapshot.self, from: json)
        #expect(snap.name == "a")
        #expect(snap.repo == "x/a")
        #expect(snap.template == nil)
        #expect(snap.branch == nil)
    }
}
