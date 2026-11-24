/// What a row's tab strip knows about docking (B-439): which panes it shows
/// now, each pane's edge, and how a tab's menu or drag moves one.
@MainActor struct LeoPaneDockStripContext {
    let hosts: @MainActor () -> Set<LeoDockPane>
    let edge: @MainActor (LeoDockPane) -> LeoDockEdge
    let move: @MainActor (LeoDockPane, LeoDockEdge) -> Void
    /// A tab of the pane started or finished a drag (B-440).
    let beginDrag: @MainActor (LeoDockPane) -> Void
    let endDrag: @MainActor () -> Void
}
