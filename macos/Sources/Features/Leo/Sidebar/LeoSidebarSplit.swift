import AppKit
import SwiftUI

enum LeoSidebarSplitMetrics {
    static let minimumWidth: CGFloat = 200
    static let maximumWidth: CGFloat = 420
    static let minimumTerminalWidth: CGFloat = 30
    static let dividerWidth: CGFloat = 6
    private static let widthChangeTolerance: CGFloat = 0.5

    static func width(preferred: CGFloat, available: CGFloat) -> CGFloat {
        let upperBound = max(minimumWidth, min(maximumWidth, available - minimumTerminalWidth - dividerWidth))
        return min(max(preferred, minimumWidth), upperBound)
    }

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
        GeometryReader { geometry in
            LeoSplitViewRepresentable(
                isSidebarVisible: session.isSidebarVisible,
                sidebarWidth: LeoSidebarSplitMetrics.width(preferred: session.preferredWidth, available: geometry.size.width),
                onDividerWidthChange: { session.setPreferredWidth($0) },
                sidebar: LeoSidebarView(model: model, windowID: session.id, actions: actions),
                detail: terminal
            )
        }
    }
}
