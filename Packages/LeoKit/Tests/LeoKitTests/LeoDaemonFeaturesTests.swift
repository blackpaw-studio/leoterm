import Testing

@testable import LeoKit

struct LeoDaemonFeaturesTests {
    @Test func advertisesMachineStats() {
        #expect(LeoDaemonFeatures(["machine_stats", "from_the_future"]).contains(.machineStats))
    }

    @Test func missingFlagMeansNoMachineStats() {
        #expect(!LeoDaemonFeatures(["agent_usage"]).contains(.machineStats))
        #expect(!LeoDaemonFeatures.none.contains(.machineStats))
    }

    @Test func advertisesAgentMove() {
        #expect(LeoDaemonFeatures(["agent_move"]).contains(.agentMove))
        #expect(!LeoDaemonFeatures.none.contains(.agentMove))
    }

    @Test func advertisesAgentShell() {
        #expect(LeoDaemonFeatures(["agent_shell"]).contains(.agentShell))
        #expect(!LeoDaemonFeatures.none.contains(.agentShell))
    }
}
