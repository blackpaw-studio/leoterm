import AppKit
import LeoKit
import Testing

@testable import Ghostty

/// The pull-down's items act on the window's own controller, not on whichever
/// responder is first (B1: they were all disabled while Chat had focus).
@MainActor
struct LeoAgentTitleMenuTargetTests {
    private let agent = LeoAgentTitleMenuItems.Context.Agent(
        availability: LeoRowActionAvailability(status: .stopped, isPending: false), host: .local, workspace: "/work/agent")

    @Test func everyCommandItemTargetsTheGivenController() {
        let controller = NSObject()
        let titleMenu = LeoAgentTitleMenu(
            target: { controller },
            context: { .init(agent: agent, movesSupported: true, appearanceSupported: true) }, fileExists: { _ in true })

        let commands = titleMenu.menu.items.filter { !$0.isSeparatorItem }
        #expect(!commands.isEmpty)
        for item in commands { #expect(item.target === controller, "\(item.title)") }
    }
}
