import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The pinned Inbox row is the window's own selection: it never touches the
/// app-wide agent selection, and anything else selected there ends it.
@MainActor struct LeoInboxSelectionTests {
    private let alpha = LeoAgentRow.ID(host: .local, name: "alpha")

    private func makeModel() -> LeoSidebarModel {
        let row = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .idle, actionDetail: nil, startedAt: "s")
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: 1))
        model.userSelected(alpha)
        return model
    }

    @Test func selectingTheInboxLeavesTheAgentSelectionIntact() {
        let model = makeModel()
        let terminals = LeoWindowTerminals()
        LeoSidebarSelection.select(.inbox, model: model, terminals: terminals)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .inbox)
        #expect(model.selection == alpha)
    }

    @Test func selectingAnAgentOrATerminalEndsTheInboxSelection() {
        let model = makeModel()
        let terminals = LeoWindowTerminals()
        let shell = UUID()
        terminals.add(shell, title: "zsh")
        LeoSidebarSelection.select(.inbox, model: model, terminals: terminals)
        LeoSidebarSelection.select(.agent(alpha), model: model, terminals: terminals)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .agent(alpha))
        LeoSidebarSelection.select(.inbox, model: model, terminals: terminals)
        LeoSidebarSelection.select(.terminal(shell), model: model, terminals: terminals)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .terminal(shell))
        #expect(!terminals.isInboxSelected)
    }

    @Test func selectingTheInboxDeselectsATerminalRow() {
        let model = makeModel()
        let terminals = LeoWindowTerminals()
        let shell = UUID()
        terminals.add(shell, title: "zsh")
        terminals.select(shell)
        LeoSidebarSelection.select(.inbox, model: model, terminals: terminals)
        #expect(terminals.selection == nil)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .inbox)
    }

    @Test func anAttachLandingInTheWindowEndsTheInboxSelection() {
        let terminals = LeoWindowTerminals()
        terminals.selectInbox()
        terminals.select(nil)
        #expect(!terminals.isInboxSelected)
    }
}
