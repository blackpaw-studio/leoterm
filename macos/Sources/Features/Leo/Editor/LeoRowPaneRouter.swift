import Foundation

/// B-274: where an action on a sidebar agent row -- Browse Files, Open
/// Surfaced File -- lands: that row's own pane, in the window that ends up
/// showing it, never the pane of the row on screen.
@MainActor struct LeoRowPaneRouter {
    /// Shows `identity` from `origin` as a click on its row does; the
    /// window that shows it then, or nil when it isn't shown (the user
    /// cancelled, or the attach failed).
    let show: @MainActor (LeoAgentIdentity, LeoWindowID) async -> LeoWindowID?
    let session: @MainActor (LeoWindowID) -> LeoWindowSession?

    /// The window is decided first, then the pane: a running agent is
    /// shown (in `origin`, or the window already showing it) and the action
    /// lands in that window's pane for it; nil when it wasn't shown. A
    /// stopped agent can't be shown without asking to start it, so the
    /// action lands in its own pane in `origin`, there when it's next shown
    /// -- the row on screen is never touched.
    func pane(for row: LeoAgentRow, from origin: LeoWindowSession) async -> (session: LeoWindowSession, pane: LeoRowPane)? {
        let key = LeoRowKey.agent(row.identity)
        guard row.status == .running else { return (origin, origin.panes.pane(for: key)) }
        guard let shown = await show(row.identity, origin.id), let destination = session(shown) else { return nil }
        return (destination, destination.panes.pane(for: key))
    }
}
