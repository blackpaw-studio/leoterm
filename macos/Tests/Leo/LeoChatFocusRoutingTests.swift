import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A request to focus an agent's terminal goes where the keyboard can be
/// seen: a terminal covered by chat hands the request to the composer.
@MainActor
struct LeoChatFocusRoutingTests {
    @Test(arguments: [
        (LeoChatLayout.terminal, LeoFocusTarget.terminal),
        (.sideBySide, .terminal),
        (.chatReplacingTerminal, .chatComposer),
    ])
    func routesByWhetherTheTerminalIsVisible(layout: LeoChatLayout, target: LeoFocusTarget) {
        #expect(LeoFocusTarget(for: layout) == target)
    }

    @Test func terminalFocusMovesWhenTheTerminalIsVisible() {
        let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
        session.setObservedChatLayout(.sideBySide)
        var moved = 0
        session.routeTerminalFocus { moved += 1 }
        #expect(moved == 1)
        #expect(session.chatFocusRequest == 0)
    }

    @Test func terminalFocusGoesToTheComposerWhenChatCoversTheTerminal() {
        let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
        session.setObservedChatLayout(.chatReplacingTerminal)
        var moved = 0
        session.routeTerminalFocus { moved += 1 }
        #expect(moved == 0)
        #expect(session.chatFocusRequest == 1)
    }

    @Test func aDeferredRequestIsRoutedByTheLayoutWhenItRuns() {
        let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
        session.setObservedChatLayout(.terminal)
        var moved = 0
        let deferred = { session.routeTerminalFocus { moved += 1 } }
        session.setObservedChatLayout(.chatReplacingTerminal)
        deferred()
        #expect(moved == 0)
        #expect(session.chatFocusRequest == 1)
    }
}
