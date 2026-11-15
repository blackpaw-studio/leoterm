import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

struct AgentMovedTests {
    @Test func aMovedAgentCarriesWhereAndWhen() {
        let observed = LeoObservedAgent(
            name: "zeus", status: .stopped, activity: nil, currentAction: nil, lastActivityAt: nil,
            movedTo: "nas", movedAt: "2026-10-28T17:00:00Z"
        )
        let agent = Agent(observed)
        #expect(agent.movedTo == "nas")
        #expect(agent.movedAt == "2026-10-28T17:00:00Z")
        #expect(agent.isMoved)
    }

    @Test func anAgentThatLivesHereIsNotMoved() {
        #expect(!Agent(.make("zeus")).isMoved)
    }

    @Test func aMovedAgentReadsAsMovedWithHowLongAgo() throws {
        let at = try #require(LeoMovedAgentWording.date(from: "2026-10-28T17:00:00Z"))
        var agent = Agent(.make("zeus", status: .stopped))
        agent.movedTo = "nas"
        agent.movedAt = "2026-10-28T17:00:00Z"
        #expect(agent.movedText(now: at.addingTimeInterval(3_600), locale: Locale(identifier: "en_US")) == "Moved to nas · 1 hour ago")
    }

    @Test func aMovedAgentCannotBeStartedOrAttached() {
        var agent = Agent(.make("zeus", status: .stopped))
        agent.movedTo = "nas"
        #expect(agent.availableCommands.isEmpty)
        #expect(!agent.canOpenTerminal)
        #expect(!agent.canMove)
    }

    @Test func aLiveAgentOffersTheUsualCommandsAndMoves() {
        let running = Agent(.make("zeus"))
        #expect(running.availableCommands == [.interrupt, .restart, .stop])
        #expect(running.canMove)
        let stopped = Agent(.make("zeus", status: .stopped))
        #expect(stopped.availableCommands == [.start])
        #expect(stopped.canMove)
    }
}
