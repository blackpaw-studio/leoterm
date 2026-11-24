/// What a row's tab strip knows about docking (B-439): which panes it shows
/// now, each pane's edge, and how a tab's menu moves one.
@MainActor struct LeoPaneDockStripContext {
    let hosts: @MainActor () -> Set<LeoDockPane>
    let edge: @MainActor (LeoDockPane) -> LeoDockEdge
    let move: @MainActor (LeoDockPane, LeoDockEdge) -> Void
}
