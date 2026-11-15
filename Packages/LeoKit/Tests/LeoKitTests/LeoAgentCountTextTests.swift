import Testing

@testable import LeoKit

struct LeoAgentCountTextTests {
    @Test func oneAgentIsSingularAndEveryOtherCountPlural() {
        #expect(LeoAgentCountText.describing(0) == "0 agents")
        #expect(LeoAgentCountText.describing(1) == "1 agent")
        #expect(LeoAgentCountText.describing(2) == "2 agents")
    }
}
