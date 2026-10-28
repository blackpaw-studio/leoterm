import Testing

@testable import LeoKit

/// B-324: deleting a moved agent's dormant record on its old host removes only
/// that host's leftover copy; the wording says so on both platforms.
struct LeoMovedAgentWordingTests {
    @Test func theLeftoverCopyPromptNamesBothHosts() {
        #expect(
            LeoMovedAgentWording.removeLeftoverTitle(on: "this Mac", movedTo: "nas")
                == "Remove leftover copy on this Mac (the agent lives on nas)"
        )
    }

    @Test func theLeftoverCopyButtonSaysRemove() {
        #expect(LeoMovedAgentWording.removeLeftoverButton == "Remove")
    }
}
