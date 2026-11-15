import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

struct AgentDisplayNameTests {
    private func observed(_ name: String, displayName: String?) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil,
            displayName: displayName
        )
    }

    @Test func anObservedAgentCarriesItsDisplayNameAndFallsBackToName() {
        #expect(Agent(observed("alfred", displayName: "Alfred")).displayName == "Alfred")
        #expect(Agent(observed("alfred", displayName: nil)).displayName == "alfred")
        #expect(Agent(observed("alfred", displayName: "  ")).displayName == "alfred")
    }

    @Test func aSpawnEventSetsTheDisplayNameAndLaterEventsKeepIt() {
        var session = DaemonSession(daemon: .dionysus)
        let spawned = LeoAgent(name: "hera", status: .starting, displayName: "Hera Prime")
        session.apply(.agentSpawned(seq: 1, at: nil, agent: spawned))
        #expect(session.agents[id: "hera"]?.displayName == "Hera Prime")

        session.apply(.agentStopped(seq: 2, at: nil, agent: "hera", wakeOnMessage: false))
        #expect(session.agents[id: "hera"]?.displayName == "Hera Prime")

        let renamed = LeoAgent(name: "hera", status: .running, displayName: "Hera")
        session.apply(.agentSpawned(seq: 3, at: nil, agent: renamed))
        #expect(session.agents[id: "hera"]?.displayName == "Hera")
    }
}
