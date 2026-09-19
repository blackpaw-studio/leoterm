import Foundation
import Testing

@testable import Ghostty

struct LeoSidebarSectioningTests {
    @Test func groupsRowsByStatusPreservingRankOrder() {
        let ranked = [
            row("a", status: .running),
            row("b", status: .starting),
            row("c", status: .stopped),
            row("d", status: .unknown("weird"))
        ]

        let sections = LeoSidebarSectioning.sections(for: ranked)

        #expect(sections.map(\.title) == ["Running", "Starting", "Stopped", "Weird"])
        #expect(sections.map { $0.rows.map(\.name) } == [["a"], ["b"], ["c"], ["d"]])
    }

    @Test func allRunningProducesSingleSection() {
        let ranked = [row("a", status: .running), row("b", status: .running)]

        let sections = LeoSidebarSectioning.sections(for: ranked)

        #expect(sections.count == 1)
        #expect(sections.first?.title == "Running")
        #expect(sections.first?.rows.map(\.name) == ["a", "b"])
    }

    @Test func allStoppedProducesSingleSection() {
        let ranked = [row("a", status: .stopped), row("b", status: .stopped)]

        let sections = LeoSidebarSectioning.sections(for: ranked)

        #expect(sections.count == 1)
        #expect(sections.first?.title == "Stopped")
    }

    @Test func filterThatEmptiesASectionOmitsItsHeader() {
        // Simulates a search query that filters visibleRows down to no
        // running agents: the "Running" header must not render with nothing
        // beneath it.
        let filtered = [row("b", status: .starting), row("c", status: .stopped)]

        let sections = LeoSidebarSectioning.sections(for: filtered)

        #expect(!sections.map(\.title).contains("Running"))
        #expect(sections.map(\.title) == ["Starting", "Stopped"])
    }

    @Test func emptyInputProducesNoSections() {
        #expect(LeoSidebarSectioning.sections(for: []).isEmpty)
    }

    private func row(_ name: String, status: LeoAgentStatus) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: status, activity: .unknown, actionDetail: nil)
    }
}
