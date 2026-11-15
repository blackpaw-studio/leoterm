import LeoFeatures
import Testing

@testable import Leo

struct AgentContextMenuTests {
    private func offering(
        agent: Agent? = Self.agent(),
        _ availability: MoveAvailability,
        appearance: Bool = true
    ) -> AgentContextMenu.Offering {
        AgentContextMenu.Offering(agent: agent, availability: availability, supportsAppearance: appearance)
    }

    private static func agent(moved: Bool = false) -> Agent {
        Agent(name: "zeus", status: .running, activity: .working, movedTo: moved ? "hestia" : nil)
    }

    @Test func anAgentTheDaemonNoLongerReportsGetsNoMenu() {
        #expect(offering(agent: nil, .hosts(["hestia"])).isEmpty)
    }

    @Test func aDaemonWithHostsOffersMoveCopyDuplicateAndAppearance() {
        let result = offering(.hosts(["hestia"]))
        #expect(result.moveHosts == ["hestia"])
        #expect(result.offersDuplicate)
        #expect(result.offersAppearance)
    }

    @Test func anAgentThatCannotMoveOffersOnlyAppearance() {
        let result = offering(agent: Self.agent(moved: true), .hosts(["hestia"]))
        #expect(result.moveHosts.isEmpty)
        #expect(!result.offersDuplicate)
        #expect(result.offersAppearance)
    }

    @Test func aDaemonWithoutMoveOrAppearanceOffersNothing() {
        #expect(offering(.unsupported, appearance: false).isEmpty)
    }

    @Test func duplicateOnlyHasNoHostSubmenus() {
        let result = offering(.duplicateOnly, appearance: false)
        #expect(result.moveHosts.isEmpty)
        #expect(result.offersDuplicate)
        #expect(!result.isEmpty)
    }
}
