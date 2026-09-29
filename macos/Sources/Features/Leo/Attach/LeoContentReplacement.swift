import Foundation

/// B-055: showing a row in a window's content area replaces what it
/// showed. Agents detach losslessly -- tmux keeps them, and the row brings
/// them back -- so replacing one never asks. A plain shell has no row to
/// come back to yet (B-057), so one with a running process asks first, in
/// Ghostty's own terms (`needsConfirmQuit`).
enum LeoContentReplacement {
    /// One surface the content area shows now.
    struct Shown: Equatable, Sendable {
        /// An attach surface (live or exited): it carries an agent's name.
        let isAgent: Bool
        let needsConfirmQuit: Bool
    }

    static func needsConfirmation(_ shown: [Shown]) -> Bool {
        shown.contains { !$0.isAgent && $0.needsConfirmQuit }
    }

    /// Whether content leaving the content area is kept attached (hidden
    /// in the window's live pool, B-056): only when every surface in it is
    /// an agent. A plain shell has no row to come back to, and D-106's
    /// consent covers closing it now, not a silent eviction later.
    static func keepsAttached(_ shown: [Shown]) -> Bool { !shown.isEmpty && shown.allSatisfy(\.isAgent) }

    static let messageText = "Close Terminal?"
    static let informativeText = "The terminal in this window still has a running process. "
        + "Showing another row here closes it, and the process will be killed."
    static let confirmButtonTitle = "Close"
}
