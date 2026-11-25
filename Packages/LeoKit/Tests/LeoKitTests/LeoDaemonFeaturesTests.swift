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

    @Test func advertisesTheInboxFeatures() {
        let features = LeoDaemonFeatures(["agent_seen", "attention.turn_failed"])
        #expect(features.contains(.agentSeen))
        #expect(features.contains(.attentionTurnFailed))
        #expect(!LeoDaemonFeatures.none.contains(.agentSeen))
    }

    @Test func advertisesAgentBrief() {
        #expect(LeoDaemonFeatures(["agent_brief"]).contains(.agentBrief))
        #expect(!LeoDaemonFeatures.none.contains(.agentBrief))
    }
}
