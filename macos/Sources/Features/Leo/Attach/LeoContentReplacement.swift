import Foundation

/// B-055: showing a row in a window's content area replaces what it
/// showed. Agents detach losslessly -- tmux keeps them, and the row brings
/// them back -- so replacing one never asks. A terminal row's layout --
/// its shell and the shells split beside it (B-333) -- is hidden, not
/// closed (B-057, D-111), so it never asks either. Only what has no row
/// to come back to -- a shell split beside an agent (B-058 territory), or
/// a window's shell Leo didn't make -- closes with the switch, and a
/// running process there asks first, in Ghostty's own terms
/// (`needsConfirmQuit`, D-106). A shell a row's closed pane left on its
/// own carries that row on (B-082), so it is kept, not closed.
enum LeoContentReplacement {
    /// One surface the content area shows now.
    struct Shown: Equatable, Sendable {
        /// An attach surface (live or exited): it carries an agent's name.
        /// What its window title and sidebar row call it (B-088).
        let name: String
        let isAgent: Bool
        /// A terminal row's own shell (B-057).
        let isTerminalRow: Bool
        let needsConfirmQuit: Bool

        init(name: String = LeoTerminalRow.untitled, isAgent: Bool, isTerminalRow: Bool = false, needsConfirmQuit: Bool) {
            self.name = name
            self.isAgent = isAgent
            self.isTerminalRow = isTerminalRow
            self.needsConfirmQuit = needsConfirmQuit
        }
    }

    /// What becomes of content leaving the content area.
    enum Fate: Equatable, Sendable {
        /// Hidden in the window's live pool (B-056), LRU-bounded.
        case pool
        /// Hidden for its terminal row's whole life (D-111).
        case keep
        /// Let go: its surfaces close.
        case close
    }

    /// All agents: the pool. A terminal row's layout: kept for that row.
    /// Anything else -- a shell split beside an agent -- closes (asking
    /// first when busy); it is never hidden, so no later eviction or close
    /// kills a shell silently (D-109).
    static func fate(_ shown: [Shown]) -> Fate {
        if keepsAttached(shown) { return .pool }
        return splitsIntoShell(shown) ? .keep : .close
    }

    /// B-333: a terminal row's layout -- its shell, and only plain shells
    /// split beside it -- which a Ghostty split (⌘D, ⇧⌘D) joins straight
    /// as a new shell, as a split in a Ghostty tab does. Anything holding
    /// an agent keeps the picker (D-212), as does a shell with no row.
    static func splitsIntoShell(_ shown: [Shown]) -> Bool {
        shown.contains(where: \.isTerminalRow) && !shown.contains(where: \.isAgent)
    }

    /// Only content that closes with the switch asks, and only for a
    /// shell with a running process.
    static func needsConfirmation(_ shown: [Shown]) -> Bool {
        fate(shown) == .close && shown.contains { !$0.isAgent && $0.needsConfirmQuit }
    }

    /// Whether content leaving the content area is pooled (B-056): only
    /// when every surface in it is an agent.
    static func keepsAttached(_ shown: [Shown]) -> Bool { !shown.isEmpty && shown.allSatisfy(\.isAgent) }

    /// Names each busy shell the switch closes (B-088).
    static func messageText(_ shown: [Shown]) -> String {
        LeoCloseConfirmation.messageText(closing: shown.filter { !$0.isAgent && $0.needsConfirmQuit }.map(\.name))
    }
    static let informativeText = "The terminal in this window still has a running process. "
        + "Showing another row here closes it, and the process will be killed."
    static let confirmButtonTitle = "Close"
}
