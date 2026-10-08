import Foundation

/// Pure decision logic backing the top-level "Agents" menu (and the two
/// Leo entries that remain in "View"): whether each command should be
/// enabled, and what a state-reflecting title should read, given only the
/// session/selection state. Deliberately AppKit-free so it is testable
/// without a window, a menu, or a `TerminalController`.
enum LeoMenuCommands {
    /// State needed to decide whether an agent-scoped command (Attach,
    /// Start, Stop, ...) is enabled: whether a Leo window session exists,
    /// and -- when one does -- the row-status-derived availability of
    /// whatever is currently *selected* in the sidebar. `nil` availability
    /// means nothing is selected.
    struct AgentContext {
        let hasLeoSession: Bool
        let availability: LeoRowActionAvailability?
    }

    /// HIG: a Show/Hide title pair, not a checkmark, is the convention for
    /// a menu item that toggles a panel's visibility.
    static func sidebarToggleTitle(hasLeoSession: Bool, isSidebarVisible: Bool) -> String {
        hasLeoSession && isSidebarVisible ? "Hide Agents Sidebar" : "Show Agents Sidebar"
    }

    /// Hide is always there; Show isn't while showing the sidebar would
    /// take the terminal under its floor beside a side pane (D-059) --
    /// disabled, so ⌘⇧L gives the system beep.
    static func canToggleSidebar(hasLeoSession: Bool, isSidebarVisible: Bool = false, showingSqueezesTerminal: Bool = false) -> Bool {
        hasLeoSession && (isSidebarVisible || !showingSqueezesTerminal)
    }

    /// Find Agent… shows a hidden sidebar, so it's gated like Show.
    static func canFindAgent(hasLeoSession: Bool, isSidebarVisible: Bool, showingSqueezesTerminal: Bool) -> Bool {
        canToggleSidebar(hasLeoSession: hasLeoSession, isSidebarVisible: isSidebarVisible, showingSqueezesTerminal: showingSqueezesTerminal)
    }

    static func canCreateAgent(hasLeoSession: Bool) -> Bool { hasLeoSession }

    static func canAttach(_ context: AgentContext) -> Bool { enabled(context) { $0.attach } }
    static func canStart(_ context: AgentContext) -> Bool { enabled(context) { $0.start } }
    static func canStop(_ context: AgentContext) -> Bool { enabled(context) { $0.stop } }
    static func canRestart(_ context: AgentContext) -> Bool { enabled(context) { $0.restart } }
    static func canSetTemplate(_ context: AgentContext) -> Bool { enabled(context) { $0.setTemplate } }
    static func canRename(_ context: AgentContext) -> Bool { enabled(context) { $0.rename } }
    static func canViewLogs(_ context: AgentContext) -> Bool { enabled(context) { $0.logs } }
    static func canDelete(_ context: AgentContext) -> Bool { enabled(context) { $0.delete } }

    /// Agents ▸ Pin Agent / Unpin Agent (⌥⌘P) on the selected row (B-010).
    static func pinToggleTitle(isPinned: Bool) -> String { isPinned ? "Unpin Agent" : "Pin Agent" }

    static func canTogglePin(_ context: AgentContext) -> Bool { context.hasLeoSession && context.availability != nil }

    static func canJumpToNextNeedingAttention(hasLeoSession: Bool, hasTarget: Bool) -> Bool { hasLeoSession && hasTarget }

    /// Agents ▸ Reconnect (⇧⌘R): the sidebar's Retry, whenever the
    /// sidebar offers one and it isn't already running.
    static func canReconnect(hasLeoSession: Bool, connectivity: LeoConnectivity) -> Bool {
        guard hasLeoSession else { return false }
        switch connectivity {
        case .disconnected(_, let isRetrying): return !isRetrying
        case .failed: return true
        case .loading, .connected: return false
        }
    }

    private static func enabled(_ context: AgentContext, _ pick: (LeoRowActionAvailability) -> Bool) -> Bool {
        guard context.hasLeoSession, let availability = context.availability else { return false }
        return pick(availability)
    }
}
