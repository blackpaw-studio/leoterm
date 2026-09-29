import Foundation

/// B-050, B-055: what a window's start screen ("No Agent Attached") holds,
/// read off its `TerminalController` so the discard decision stays pure.
///
/// "Untouched" means nothing the user made would be lost or hidden by
/// closing it: the window is still the start screen it was created as
/// (`leoIsUnfilledPlaceholder`), has no terminal (so nothing was ever
/// typed in it -- the start screen has no terminal to type into; the
/// terminal drawer is the app-wide quick terminal, not part of the
/// window), and shows no editor or browser pane. A window has one content
/// area and no tabs (D-098), so there is nothing beside it to count.
struct LeoStartScreenState: Equatable, Sendable {
    let isUnfilledPlaceholder: Bool
    let hasTerminal: Bool
    let isEditorOpen: Bool
    let isBrowserOpen: Bool

    var isUntouched: Bool { isUnfilledPlaceholder && !hasTerminal && !isEditorOpen && !isBrowserOpen }
}
