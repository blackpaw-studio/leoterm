import Testing

@testable import LeoFeatures

struct AgentDetailSectionPlanTests {
    private typealias Section = AgentDetailSection

    private func plan(_ counts: [Section: Int]) -> AgentDetailSectionPlan {
        AgentDetailSectionPlan(itemCounts: counts)
    }

    @Test func noBriefMeansNoBriefSectionAndNoBriefHeader() {
        let plan = plan([.header: 1, .live: 3, .status: 4, .actions: 2, .brief: 0])

        #expect(!plan.sections.contains(.brief))
        #expect(!plan.headedSections.contains(.brief))
    }

    @Test func aBriefAddsItsSectionAndHeaderBeforeTheLiveRows() {
        let plan = plan([.header: 1, .live: 3, .brief: 5, .status: 4])

        #expect(plan.sections == [.header, .brief, .live, .status])
        #expect(plan.headedSections.contains(.brief))
    }

    @Test func aSectionIsFoundByItsPositionAmongTheVisibleOnes() {
        // With the brief section absent, position 1 is the live rows, not the brief.
        let plan = plan([.header: 1, .live: 3, .status: 4])

        #expect(plan.section(at: 1) == .live)
        #expect(plan.section(at: 2) == .status)
        #expect(plan.section(at: 3) == nil)
    }

    @Test func theIdentityBlockAndTheOpenInClaudeCardHaveNoHeader() {
        let plan = plan([.header: 1, .claude: 1, .live: 2])

        #expect(plan.headedSections.isEmpty)
    }
}
