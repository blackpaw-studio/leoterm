import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A request to focus an agent's terminal goes where the keyboard can be
/// seen: a terminal covered by chat hands the request to the composer.
@MainActor
struct LeoChatFocusRoutingTests {
    private static let a = LeoAgentID(host: .local, name: "a")
    private static let b = LeoAgentID(host: .local, name: "b")

    @Test(arguments: [
        (LeoChatLayout.terminal, LeoFocusTarget.terminal),
        (.sideBySide, .terminal),
        (.chatReplacingTerminal, .chatComposer),
    ])
    func routesByWhetherTheTerminalIsVisible(layout: LeoChatLayout, target: LeoFocusTarget) {
        #expect(LeoFocusTarget(for: layout) == target)
    }

    /// A session whose sidebar selection is `selected`, with `chatAgents`
    /// remembered in Chat mode in a window wide or narrow as asked.
    private func makeSession(selected: LeoAgentID?, chatAgents: [LeoAgentID] = [], contentWidth: CGFloat) -> LeoWindowSession {
        let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
        session.selectedAgent = { selected }
        session.setObservedContentWidth(contentWidth)
        chatAgents.forEach { session.choose(.chat, for: $0) }
        return session
    }

    private func gate(of session: LeoWindowSession) -> () -> Bool {
        var gate: (() -> Bool)?
        session.routeTerminalFocus { gate = $0 }
        return gate ?? { true }
    }

    @Test func terminalMayTakeFocusWhenTheSelectedAgentIsInTerminalMode() {
        let session = makeSession(selected: Self.a, contentWidth: 800)
        let before = session.chatFocusRequest
        #expect(gate(of: session)())
        #expect(session.chatFocusRequest == before)
    }

    @Test func terminalMayTakeFocusSideBySide() {
        let session = makeSession(selected: Self.a, chatAgents: [Self.a], contentWidth: 1400)
        #expect(gate(of: session)())
    }

    @Test func terminalFocusGoesToTheComposerWhenChatCoversTheTerminal() {
        let session = makeSession(selected: Self.a, chatAgents: [Self.a], contentWidth: 800)
        let before = session.chatFocusRequest
        #expect(!gate(of: session)())
        #expect(session.chatFocusRequest == before + 1)
    }

    @Test func aFocusQueuedForAnAgentWhoseRememberedModeIsChatNeverReachesTheTerminal() {
        // Agent A shows its terminal; B remembers Chat. Focus is queued while
        // A is selected (the render hasn't caught up), then the selection moves to B.
        var selected: LeoAgentID? = Self.a
        let session = makeSession(selected: nil, chatAgents: [Self.b], contentWidth: 800)
        session.selectedAgent = { selected }
        let queued = gate(of: session)
        selected = Self.b
        #expect(!queued())
        #expect(!queued(), "a retry is asked again, not remembered")
    }

    @Test func aRetryAfterTheModeFlipsBackMayFocusTheTerminal() {
        let session = makeSession(selected: Self.a, chatAgents: [Self.a], contentWidth: 800)
        let queued = gate(of: session)
        #expect(!queued())
        session.choose(.terminal, for: Self.a)
        #expect(queued())
    }

    @Test func aTerminalRowSelectionAlwaysAllowsTheTerminal() {
        let session = makeSession(selected: nil, contentWidth: 800)
        #expect(gate(of: session)())
    }
}
