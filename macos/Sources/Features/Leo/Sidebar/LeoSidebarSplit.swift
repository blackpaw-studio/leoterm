import AppKit
import SwiftUI

enum LeoSidebarSplitMetrics {
    static let minimumWidth: CGFloat = 200
    static let maximumWidth: CGFloat = 420
    static let minimumTerminalWidth: CGFloat = 30
    /// The width the terminal keeps when the browser or editor opens
    /// (D-036): below it, the agents sidebar collapses first. Not a hard
    /// minimum -- if that isn't enough, the pane opens anyway and the
    /// terminal gives way down to `minimumTerminalWidth`.
    static let terminalFloor: CGFloat = 300

    /// What's left for the terminal in a split `splitWidth` wide beside
    /// panes `paneWidths` wide and `dividers` dividers.
    static func terminalWidth(splitWidth: CGFloat, paneWidths: [CGFloat], dividers: Int, dividerThickness: CGFloat) -> CGFloat {
        splitWidth - paneWidths.reduce(0, +) - CGFloat(max(dividers, 0)) * dividerThickness
    }
    /// The width a pane opens at (the editor, D-038): half of `sharedWidth`,
    /// what it shares with the terminal, but never taking the terminal
    /// under `terminalFloor` -- nor the pane under its own `minimum`, which
    /// wins (the pane opens anyway, as with D-036).
    static func openingPaneWidth(sharedWidth: CGFloat, minimum: CGFloat) -> CGFloat {
        max(minimum, min((sharedWidth / 2).rounded(.down), sharedWidth - terminalFloor))
    }

    /// Whether panes `paneWidths` wide (the sidebar and side panes shown
    /// beside the terminal, a divider each) leave the terminal under
    /// `terminalFloor` in a split `splitWidth` wide.
    static func squeezesTerminal(splitWidth: CGFloat, paneWidths: [CGFloat], dividerThickness: CGFloat) -> Bool {
        terminalWidth(splitWidth: splitWidth, paneWidths: paneWidths, dividers: paneWidths.count, dividerThickness: dividerThickness)
            < terminalFloor
    }

    /// What the split does to keep the terminal floor after a layout
    /// (D-058, D-059).
    enum FloorStep: Equatable {
        case none
        /// Collapse the agents sidebar, as when a pane opens (D-036).
        case collapseSidebar
        /// Take this much from the side panes -- each down to its minimum
        /// at most -- and give it to the terminal.
        case widenTerminal(by: CGFloat)
        /// Give this much back to the side pane the floor squeezed.
        case growPane(by: CGFloat)
        /// Bring back the sidebar the floor collapsed.
        case restoreSidebar
    }

    /// The split as a layout leaves it.
    struct FloorState: Equatable {
        var terminalWidth: CGFloat
        /// Since the last layout: under zero, the window narrowed.
        var splitWidthChange: CGFloat
        var isSidebarShown: Bool
        var isSidePaneShown: Bool
        /// How far the side pane the floor squeezed is under its earlier
        /// width.
        var paneRegrowth: CGFloat = 0
        /// The width (divider included) of the sidebar the floor
        /// collapsed; nil when it's shown or the user hid it.
        var restorableSidebarWidth: CGFloat?
    }

    /// Room the terminal keeps above its floor beside a sidebar coming
    /// back, so a window jiggled where it collapsed doesn't flip it.
    static let sidebarRestoreSlack: CGFloat = 24

    /// Only a resize acts -- never a divider drag or a pane opening.
    /// Narrowing with the terminal under its floor collapses the sidebar
    /// first, then the side panes give way. Widening undoes that in
    /// reverse: the squeezed pane grows back first, then the sidebar the
    /// floor collapsed returns (with `sidebarRestoreSlack`), and only then
    /// does the terminal keep the extra.
    static func floorStep(_ state: FloorState) -> FloorStep {
        if state.splitWidthChange < -widthChangeTolerance {
            let deficit = terminalFloor - state.terminalWidth
            guard state.isSidePaneShown, deficit > widthChangeTolerance else { return .none }
            return state.isSidebarShown ? .collapseSidebar : .widenTerminal(by: deficit)
        }
        guard state.splitWidthChange > widthChangeTolerance else { return .none }
        let room = state.terminalWidth - terminalFloor
        if state.paneRegrowth > widthChangeTolerance, room > widthChangeTolerance {
            return .growPane(by: min(state.paneRegrowth, room))
        }
        if let sidebarWidth = state.restorableSidebarWidth, room - sidebarWidth >= sidebarRestoreSlack {
            return .restoreSidebar
        }
        return .none
    }

    /// Width of the split view's divider, used by `TerminalController` when
    /// sizing a window that shows the sidebar. `NSSplitView.dividerStyle` is
    /// `.thin`, which the HIG defines as 1 pt.
    static let dividerWidth: CGFloat = 1
    private static let widthChangeTolerance: CGFloat = 0.5

    /// Holding priorities for the two panes.
    ///
    /// `NSSplitView` resizes the pane with the *lower* holding priority
    /// first, so the sidebar outranking the terminal is what makes the
    /// terminal absorb window resizes while the sidebar keeps its width.
    ///
    /// Their order decides which pane absorbs a window resize, but only
    /// within `NSSplitView`'s low holding-priority band (`NSSplitViewItem`
    /// itself defaults to 260 for a sidebar item and 250 for a plain one).
    /// The absolute values matter too: the band is what keeps the divider
    /// draggable at all.
    /// Raising the sidebar's to `.defaultHigh` (750) -- which is what this
    /// used to do -- silently freezes the pane at `minimumWidth`: the split
    /// view stops updating its `NSSplitView.PreferredSize.0` constraint, so
    /// the divider renders its resize cursor but cannot be dragged, and
    /// `setPosition(_:ofDividerAt:)` becomes a no-op.
    static let sidebarHoldingPriority = NSLayoutConstraint.Priority(260)
    static let detailHoldingPriority = NSLayoutConstraint.Priority(250)
    /// Between the two: the terminal still absorbs window resizes, and the
    /// editor keeps its width like the sidebar.
    static let editorHoldingPriority = NSLayoutConstraint.Priority(255)
    /// Likewise for the workspace browser on the editor's leading edge.
    static let browserHoldingPriority = NSLayoutConstraint.Priority(256)

    /// Whether a sidebar width reported back by the split view should be
    /// written to `session.preferredWidth`.
    ///
    /// A collapsed pane never persists (its reported width is meaningless),
    /// and a width that hasn't actually moved from the last value we
    /// recorded is ignored -- this is what keeps the layout pass that
    /// *applies* a stored preference from looping back into persisting
    /// itself, without needing to sniff whether the change came from a
    /// mouse drag.
    static func shouldPersist(newWidth: CGFloat, lastPersistedWidth: CGFloat, isCollapsed: Bool) -> Bool {
        guard !isCollapsed else { return false }
        return abs(newWidth - lastPersistedWidth) > widthChangeTolerance
    }
}

/// A real `NSSplitView`-backed split (via `NSSplitViewController`, bridged
/// into SwiftUI) between the agents sidebar and the terminal. This gives the
/// sidebar the system sidebar material, the HIG 1 pt divider, a genuine
/// collapse (the sidebar pane is removed from the view tree entirely when
/// hidden, not just made zero-width/transparent), and a real accessibility
/// splitter that VoiceOver can adjust.
///
/// `NavigationSplitView` was considered and rejected: it has no public API
/// to read back the width the user drags the divider to, which this view
/// needs in order to persist `session.preferredWidth` the same way the
/// previous hand-rolled divider did.
///
/// SwiftUI's `HSplitView` was also tried and rejected: it doesn't expose the
/// underlying `NSSplitView`'s delegate or resize notifications, so there is
/// no authoritative signal for "the user just moved the divider" -- only
/// sniffing `NSApp.currentEvent.type == .leftMouseDragged`, which is stale
/// global state (it misfires whenever the *previous* dispatched event
/// happened to be an unrelated drag) and produces no event at all for
/// VoiceOver or keyboard-driven divider adjustment. Going straight to
/// `NSSplitViewController` gives us the real thing instead.
struct LeoSidebarSplit<Terminal: View>: View {
    @ObservedObject var session: LeoWindowSession
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var actions: LeoAgentActions
    private let terminal: Terminal

    init(session: LeoWindowSession, model: LeoSidebarModel, actions: LeoAgentActions, @ViewBuilder terminal: () -> Terminal) {
        self.session = session
        self.model = model
        self.actions = actions
        self.terminal = terminal()
    }

    var body: some View {
        // No `GeometryReader`: the split view owns the sidebar's width while
        // the app is running (clamped by the split view items'
        // `minimumThickness`/`maximumThickness`), so nothing here needs the
        // available width. A `GeometryReader` would force this body to
        // re-evaluate on every layout pass, which is what previously
        // re-entered `setPosition` mid-drag and fought the user.
        LeoSplitViewRepresentable(
            isSidebarVisible: session.isSidebarVisible,
            preferredWidth: session.preferredWidth,
            onDividerWidthChange: { session.setPreferredWidth($0) },
            sidebar: LeoSidebarView(model: model, windowID: session.id, actions: actions),
            detail: terminal,
            editor: session.editor,
            browser: session.browser,
            onEditorPane: { session.editorPane = $0 },
            onBrowserPane: { session.browserPane = $0 },
            // Not `setSidebarVisible`: an automatic collapse isn't the
            // user's preference for new windows.
            onSidebarAutoCollapse: { session.isSidebarVisible = false },
            // Nor is it coming back once the window widens (D-059).
            onSidebarAutoRestore: { session.isSidebarVisible = true }
        )
    }
}
