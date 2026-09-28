import Foundation

/// B-050: what a tab's start screen ("No Agent Attached") holds, read off
/// its `TerminalController` so the fill-or-open decision stays pure.
///
/// "Untouched" means nothing the user made would be lost or hidden by
/// putting an agent there: the tab is still the start screen it was
/// created as (`leoIsUnfilledPlaceholder`), has no terminal (so nothing
/// was ever typed in it -- the start screen has no terminal to type into;
/// the terminal drawer is the app-wide quick terminal, not part of the
/// tab), and shows no editor or browser pane.
struct LeoStartTabState: Equatable, Sendable {
    let isUnfilledPlaceholder: Bool
    let hasTerminal: Bool
    let isEditorOpen: Bool
    let isBrowserOpen: Bool
    /// Tabs in the tab's window, itself included.
    let tabCount: Int

    var isUntouched: Bool { isUnfilledPlaceholder && !hasTerminal && !isEditorOpen && !isBrowserOpen }

    /// The window's only tab is an untouched start screen: an attach
    /// asked of this window goes there instead of into a new tab.
    var isLoneUntouched: Bool { isUntouched && tabCount <= 1 }
}
