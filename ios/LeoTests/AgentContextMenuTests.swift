import LeoFeatures
import Testing

@testable import Leo

struct AgentContextMenuTests {
    private func offering(
        canMove: Bool = true,
        _ availability: MoveAvailability,
        appearance: Bool = true
    ) -> AgentContextMenu.Offering {
        AgentContextMenu.Offering(canMove: canMove, availability: availability, supportsAppearance: appearance)
    }

    @Test func aDaemonWithHostsOffersMoveCopyDuplicateAndAppearance() {
        let result = offering(.hosts(["hestia"]))
        #expect(result.moveHosts == ["hestia"])
        #expect(result.offersDuplicate)
        #expect(result.offersAppearance)
    }

    @Test func anAgentThatCannotMoveOffersOnlyAppearance() {
        let result = offering(canMove: false, .hosts(["hestia"]))
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
