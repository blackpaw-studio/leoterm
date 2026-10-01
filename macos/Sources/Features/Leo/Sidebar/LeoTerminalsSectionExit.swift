import SwiftUI

/// B-081: the Terminals section sits below every agent and its selected
/// row is revealed there (B-067), so when the window's last terminal row
/// closes, the section goes from under the list's bottom edge and leaves
/// it scrolled to the end of the agents. The list lands instead on the
/// window's selection -- the agent it falls back to -- or, with no
/// selected agent listed, its top.
///
/// Calm (P2, D-130): the list's own minimal scroll, without animation, so
/// a selected row already on screen doesn't move; only the section's
/// closing does this, never the filter hiding it (that change comes with
/// `isFiltering`, even when no agent matches and the list empties) or the
/// agents arriving above it.
struct LeoTerminalsSectionExit: ViewModifier {
    /// Whether the Terminals section is in the list.
    let isListed: Bool
    /// Whether the search filter has text (which hides the section).
    let isFiltering: Bool
    /// Where the list lands; see `LeoTerminalsSectionExit.landing`.
    let landing: Landing?
    let proxy: ScrollViewProxy

    /// Whether the section was listed as of the last change seen.
    @State private var wasListed = false

    /// What a landing follows. The landing itself is in it so the change
    /// that closes the section reads the current one (the action's
    /// captures date from the update before; only its argument is current).
    private struct Trigger: Equatable {
        let isListed: Bool
        let isFiltering: Bool
        let landing: Landing?
    }

    func body(content: Content) -> some View {
        content
            .onAppear { wasListed = isListed }
            .onChange(of: trigger) { settle($0) }
    }

    private var trigger: Trigger { Trigger(isListed: isListed, isFiltering: isFiltering, landing: landing) }

    /// Runs a turn later: the change that closed the section may still be
    /// removing it, and the list only knows where a row is once that lands.
    private func settle(_ trigger: Trigger) {
        let didClose = wasListed && !trigger.isListed && !trigger.isFiltering
        wasListed = trigger.isListed
        guard didClose, let landing = trigger.landing else { return }
        DispatchQueue.main.async { [proxy] in landing.scroll(proxy) }
    }
}

extension LeoTerminalsSectionExit {
    /// A row or section header to land on. Scrolled to by its own id type:
    /// the list finds an id only as the type `.id` gave it, never wrapped.
    enum Landing: Equatable {
        case row(LeoSidebarItemID)
        case section(LeoSidebarSectionAnchor)

        func scroll(_ proxy: ScrollViewProxy) {
            switch self {
            case .row(let id): proxy.scrollTo(id)
            case .section(let anchor): proxy.scrollTo(anchor)
            }
        }
    }

    /// Where the list lands once the section closes: the selected agent's
    /// row, if an expanded section lists it; else the first section's
    /// header (the list's top). Nil with no sections.
    static func landing(selectedAgent: LeoAgentRow.ID?, in sections: [LeoSidebarSection]) -> Landing? {
        let isListed = { (agent: LeoAgentRow.ID) in
            sections.contains { !$0.isCollapsed && $0.rows.contains { $0.id == agent } }
        }
        if let selectedAgent, isListed(selectedAgent) { return .row(.agent(selectedAgent)) }
        return sections.first.map { .section(LeoSidebarSectionAnchor(sectionID: $0.id)) }
    }
}

/// A section's scroll id in the sidebar list.
struct LeoSidebarSectionAnchor: Hashable {
    let sectionID: String
}

extension View {
    func leoLandsWhenTerminalsClose(
        isListed: Bool, isFiltering: Bool, landing: LeoTerminalsSectionExit.Landing?, proxy: ScrollViewProxy
    ) -> some View {
        modifier(LeoTerminalsSectionExit(isListed: isListed, isFiltering: isFiltering, landing: landing, proxy: proxy))
    }
}
