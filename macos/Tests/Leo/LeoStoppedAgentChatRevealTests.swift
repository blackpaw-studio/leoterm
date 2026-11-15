import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-369: keyboard paths to a stopped agent show its chat even while the
/// window has a shell tab selected (the chat only shows for an agent row
/// when no terminal is selected).
@MainActor struct LeoStoppedAgentChatRevealTests {
    private struct Fixture {
        let registry: LeoWindowSessionRegistry
        let session: LeoWindowSession
        let model: LeoSidebarModel
        let agent: LeoAgentRow
    }

    /// A window with one shell tab selected and a stopped agent "alpha".
    private func makeFixture() -> Fixture {
        let agent = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .stopped, activity: .idle, actionDetail: nil)
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [agent], connectivity: .connected, generation: 1))
        let registry = LeoWindowSessionRegistry()
        let session = registry.makeSession(defaults: LeoInMemoryDefaults())
        model.chatRequested = { [weak registry, weak model] row, origin in
            guard let model else { return }
            registry?.showChat(of: row, in: origin, model: model)
        }
        let shell = UUID()
        session.terminals.add(shell, title: "shell")
        session.terminals.select(shell)
        return Fixture(registry: registry, session: session, model: model, agent: agent)
    }

    private func expectChatShown(_ fixture: Fixture) {
        #expect(fixture.session.terminals.selection == nil, "the shell tab must give way, or the chat never shows")
        #expect(fixture.model.actionableSelection?.id == fixture.agent.id)
        #expect(fixture.session.viewChoices[fixture.agent.id] == .chat)
        #expect(fixture.model.startPrompt(in: fixture.session.id) == nil)
    }

    @Test func rowNumberCommandShowsAStoppedAgentsChatOverAShellTab() {
        let fixture = makeFixture()

        LeoRowCommands.perform(.number(1), model: fixture.model, terminals: fixture.session.terminals, from: fixture.session.id)

        expectChatShown(fixture)
    }

    @Test func searchReturnShowsAStoppedAgentsChatOverAShellTab() {
        let fixture = makeFixture()
        fixture.model.query = "alp"

        fixture.model.searchSubmit(from: fixture.session.id)

        expectChatShown(fixture)
    }
}
