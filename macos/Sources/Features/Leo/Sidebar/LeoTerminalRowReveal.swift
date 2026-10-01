import SwiftUI

/// B-067: the Terminals section sits below every agent, so the window's
/// selected terminal row is scrolled into view whenever it's newly
/// selected (⌘T adds and selects one) or newly listed (the section shows
/// again once the search filter clears, or the list itself reappears) --
/// as Mail and Finder reveal their selection. The scroll is the list's
/// own minimal one, without animation; a row already on screen doesn't
/// move, and nothing else (a retitle, an agent refresh) scrolls.
struct LeoTerminalRowReveal: ViewModifier {
    /// The window's selected terminal row, if any.
    let selection: UUID?
    /// Whether the Terminals section is in the list.
    let isListed: Bool
    /// Whether the agents are in the list above the section, rather than a
    /// state (Loading, No Agents) standing in for them: their arriving or
    /// going moves the section, as the list reappearing did (B-099).
    let listsAgents: Bool
    let proxy: ScrollViewProxy

    /// What a reveal follows: a change to any part. A refresh of agents
    /// already listed isn't one (D-130).
    private struct Trigger: Equatable {
        let selection: UUID?
        let isListed: Bool
        let listsAgents: Bool
    }

    func body(content: Content) -> some View {
        content
            .onAppear { reveal(trigger) }
            // The action's captures date from the update before; only
            // its argument is current.
            .onChange(of: trigger) { reveal($0) }
    }

    private var trigger: Trigger { Trigger(selection: selection, isListed: isListed, listsAgents: listsAgents) }

    /// Runs a turn later: the change that prompted it may be inserting the
    /// row, and the list only knows where it is once that lands. That turn
    /// isn't ordered after AppKit's layout pass, so a change that also
    /// resizes the list -- the agents arriving where Loading stood -- can
    /// be revealed against the old size and leave the row cut off.
    private func reveal(_ trigger: Trigger) {
        guard trigger.isListed, let selection = trigger.selection else { return }
        DispatchQueue.main.async { [proxy] in proxy.scrollTo(LeoSidebarItemID.terminal(selection)) }
    }
}

extension View {
    func leoRevealsTerminalRow(_ selection: UUID?, isListed: Bool, listsAgents: Bool, proxy: ScrollViewProxy) -> some View {
        modifier(LeoTerminalRowReveal(selection: selection, isListed: isListed, listsAgents: listsAgents, proxy: proxy))
    }
}
