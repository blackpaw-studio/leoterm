import Foundation

/// A row in a window's sidebar list: an agent (app-wide) or one of this
/// window's terminals (B-057).
enum LeoSidebarItemID: Hashable, Sendable {
    case agent(LeoAgentRow.ID)
    case terminal(UUID)
}

/// B-057: one window's sidebar selection, composed from the app-wide agent
/// selection (`LeoSidebarModel.selection`, shared by every window) and the
/// window's own terminal selection (`LeoWindowTerminals.selection`). A
/// selected terminal wins in its window; selecting an agent there clears
/// it. Neither side's storage changes shape, so the shared agent list
/// behaves as before in every window.
@MainActor enum LeoSidebarSelection {
    static func current(model: LeoSidebarModel, terminals: LeoWindowTerminals) -> LeoSidebarItemID? {
        terminals.selection.map(LeoSidebarItemID.terminal) ?? model.selection.map(LeoSidebarItemID.agent)
    }

    /// The list's own selection change (click, arrow keys): selects only,
    /// never shows.
    static func select(_ item: LeoSidebarItemID?, model: LeoSidebarModel, terminals: LeoWindowTerminals) {
        switch item {
        case .terminal(let id):
            terminals.select(id)
        case .agent(let id):
            terminals.select(nil)
            model.userSelected(id)
        case nil:
            terminals.select(nil)
            model.userSelected(nil)
        }
    }

    /// Return on the list: the same as clicking the selected row.
    static func activate(model: LeoSidebarModel, terminals: LeoWindowTerminals, from origin: LeoWindowID) {
        guard let terminal = terminals.selection else { return model.activateSelection(from: origin) }
        terminals.activate(terminal)
    }

    /// Whether Return has a row to act on.
    static func canActivate(model: LeoSidebarModel, terminals: LeoWindowTerminals) -> Bool {
        terminals.selection != nil || model.actionableSelection != nil
    }
}
