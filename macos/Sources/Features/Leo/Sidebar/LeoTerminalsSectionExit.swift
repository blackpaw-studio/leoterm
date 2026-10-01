import AppKit
import Combine
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
/// agents arriving above it. And only when the section showed on screen
/// as it closed (B-105): scrolled off below, its going moves nothing the
/// user sees, so the list stays where they put it. That reads the
/// section as of the terminals' last change, which is the closing only
/// while the filter is empty -- one more reason for the filter guard.
struct LeoTerminalsSectionExit: ViewModifier {
    /// Whether the Terminals section is in the list.
    let isListed: Bool
    /// Whether the search filter has text (which hides the section).
    let isFiltering: Bool
    /// Where the list lands; see `LeoTerminalsSectionExit.landing`.
    let landing: Landing?
    /// Where the section shows (B-105), snapshotted on `terminalsWillChange`.
    let viewport: LeoTerminalsViewport
    /// The window's terminals about to change: the only way the section
    /// closes while the filter is empty.
    let terminalsWillChange: ObservableObjectPublisher
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
            .onReceive(terminalsWillChange) { viewport.snapshot() }
            .onChange(of: trigger) { settle($0) }
    }

    private var trigger: Trigger { Trigger(isListed: isListed, isFiltering: isFiltering, landing: landing) }

    /// Runs a turn later: the change that closed the section may still be
    /// removing it, and the list only knows where a row is once that lands.
    private func settle(_ trigger: Trigger) {
        let didClose = wasListed && !trigger.isListed && !trigger.isFiltering
        wasListed = trigger.isListed
        guard didClose, let scrollView = viewport.shownIn, let landing = trigger.landing else { return }
        DispatchQueue.main.async { [proxy] in landing.scroll(proxy, scrollView: scrollView) }
    }
}

extension LeoTerminalsSectionExit {
    /// A row to land on, or the list's top.
    enum Landing: Equatable {
        case row(LeoSidebarItemID)
        /// Where the list launches (B-105): above the first section's
        /// header by the list's top margin, which `scrollTo` on that
        /// header can't reach, so the list's scroll view goes there itself.
        case top

        @MainActor func scroll(_ proxy: ScrollViewProxy, scrollView: NSScrollView) {
            switch self {
            case .row(let id): proxy.scrollTo(id)
            case .top: LeoTerminalsViewport.scrollToTop(scrollView)
            }
        }
    }

    /// Where the list lands once the section closes: the selected agent's
    /// row, if an expanded section lists it; else the list's top. Nil with
    /// no sections.
    static func landing(selectedAgent: LeoAgentRow.ID?, in sections: [LeoSidebarSection]) -> Landing? {
        let isListed = { (agent: LeoAgentRow.ID) in
            sections.contains { !$0.isCollapsed && $0.rows.contains { $0.id == agent } }
        }
        if let selectedAgent, isListed(selectedAgent) { return .row(.agent(selectedAgent)) }
        return sections.isEmpty ? nil : .top
    }
}

extension View {
    func leoLandsWhenTerminalsClose(
        isListed: Bool, isFiltering: Bool, landing: LeoTerminalsSectionExit.Landing?,
        viewport: LeoTerminalsViewport, terminalsWillChange: ObservableObjectPublisher, proxy: ScrollViewProxy
    ) -> some View {
        modifier(LeoTerminalsSectionExit(
            isListed: isListed, isFiltering: isFiltering, landing: landing,
            viewport: viewport, terminalsWillChange: terminalsWillChange, proxy: proxy
        ))
    }
}
