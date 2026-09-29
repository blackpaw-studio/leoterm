import Foundation

/// B-055: showing a row in a window's content area replaces what it
/// showed. Agents detach losslessly -- tmux keeps them, and the row brings
/// them back -- so replacing one never asks. A terminal row's shell is
/// hidden, not closed (B-057, D-111), so it never asks either. Only what
/// has no row to come back to -- a shell split beside an agent or a row
/// (B-058 territory), or a window's shell Leo didn't make -- closes with
/// the switch, and a running process there asks first, in Ghostty's own
/// terms (`needsConfirmQuit`, D-106).
enum LeoContentReplacement {
    /// One surface the content area shows now.
    struct Shown: Equatable, Sendable {
        /// An attach surface (live or exited): it carries an agent's name.
        let isAgent: Bool
        /// A terminal row's own shell (B-057).
        let isTerminalRow: Bool
        let needsConfirmQuit: Bool

        init(isAgent: Bool, isTerminalRow: Bool = false, needsConfirmQuit: Bool) {
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

    /// All agents: the pool. Nothing but a terminal row's shell: kept for
    /// that row. Anything else -- a shell split beside an agent or a row --
    /// closes (asking first when busy); it is never hidden, so no later
    /// eviction or close kills a shell silently (D-109).
    static func fate(_ shown: [Shown]) -> Fate {
        if keepsAttached(shown) { return .pool }
        return !shown.isEmpty && shown.allSatisfy(\.isTerminalRow) ? .keep : .close
    }

    /// Only content that closes with the switch asks, and only for a
    /// shell with a running process.
    static func needsConfirmation(_ shown: [Shown]) -> Bool {
        fate(shown) == .close && shown.contains { !$0.isAgent && $0.needsConfirmQuit }
    }

    /// Whether content leaving the content area is pooled (B-056): only
    /// when every surface in it is an agent.
    static func keepsAttached(_ shown: [Shown]) -> Bool { !shown.isEmpty && shown.allSatisfy(\.isAgent) }

    static let messageText = "Close Terminal?"
    static let informativeText = "The terminal in this window still has a running process. "
        + "Showing another row here closes it, and the process will be killed."
    static let confirmButtonTitle = "Close"
}
