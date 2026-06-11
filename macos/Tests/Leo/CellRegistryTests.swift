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
}
