import Testing
import Foundation
@testable import Ghostty

struct CellRegistryTests {
    @Test func recordsAndLooksUpSource() {
        var reg = CellRegistry()
        let id = UUID()
        reg.record(id: id, source: .agent(name: "olympus"))
        #expect(reg.source(for: id) == .agent(name: "olympus"))
    }

    @Test func defaultsToPTYWhenUnknown() {
        let reg = CellRegistry()
        #expect(reg.source(for: UUID()) == .pty)
    }

    @Test func forgetRemovesEntry() {
        var reg = CellRegistry()
        let id = UUID()
        reg.record(id: id, source: .agent(name: "a"))
        reg.forget(id: id)
        #expect(reg.source(for: id) == .pty)
    }

    @Test func agentNamesListsOnlyAgents() {
        var reg = CellRegistry()
        let a = UUID(); let b = UUID()
        reg.record(id: a, source: .agent(name: "a"))
        reg.record(id: b, source: .pty)
        #expect(reg.agentNames.sorted() == ["a"])
    }

    @Test func agentNamesInRestrictsToLiveSurfaces() {
        // Regression: closing a cell left its entry behind, so the sidebar kept
        // showing an "on board" checkmark for an agent no longer on the board.
        var reg = CellRegistry()
        let live = UUID(); let closed = UUID()
        reg.record(id: live, source: .agent(name: "live"))
        reg.record(id: closed, source: .agent(name: "closed"))
        #expect(reg.agentNames(in: [live]).sorted() == ["live"])
    }

    @Test func agentNamesInIgnoresUnknownIDs() {
        var reg = CellRegistry()
        let id = UUID()
        reg.record(id: id, source: .agent(name: "a"))
        #expect(reg.agentNames(in: [id, UUID()]).sorted() == ["a"])
    }

    @Test func firstIDForAgentFindsAnExistingCell() {
        var reg = CellRegistry()
        let id = UUID()
        reg.record(id: id, source: .agent(name: "a"))
        #expect(reg.id(forAgent: "a", in: [id]) == id)
        #expect(reg.id(forAgent: "a", in: []) == nil)
        #expect(reg.id(forAgent: "b", in: [id]) == nil)
    }

    @Test func containsOnlyAgentsIsFalseForPTYAndUnknownCells() {
        var reg = CellRegistry()
        let agent = UUID(); let pty = UUID()
        reg.record(id: agent, source: .agent(name: "a"))
        reg.record(id: pty, source: .pty)
        #expect(reg.containsOnlyAgents([agent]))
        #expect(!reg.containsOnlyAgents([agent, pty]))
        #expect(!reg.containsOnlyAgents([UUID()]))
        #expect(!reg.containsOnlyAgents([]))
    }
}
