import Foundation

/// Pure planning helpers that translate between a persisted `Board` and the
/// cells a controller should create. Kept free of AppKit so it is testable.
enum BoardSession {
    /// A cell the controller should materialize on restore.
    struct PlannedCell: Equatable {
        let source: CellSource
        let snapshot: AgentSnapshot?
        /// True when the agent is gone — render a dead placeholder instead of a surface.
        let isDead: Bool
    }

    /// Decide, per saved cell, whether to attach a live surface or show a dead cell.
    static func restorePlan(board: Board, liveAgents: [Agent]) -> [PlannedCell] {
        let reconciled = board.reconciled(against: liveAgents)
        return reconciled.cells.map { cell in
            PlannedCell(
                source: cell.source,
                snapshot: cell.lastKnownAgent,
                isDead: cell.liveness == .dead
            )
        }
    }

    /// Build a persistable board from the current planned/live cells, binding it
    /// to `host` so the board reattaches to the same leo host on restore.
    static func snapshot(
        name: String,
        host: String,
        from cells: [PlannedCell],
        pinnedRowHeights: [Int: CGFloat] = [:]
    ) -> Board {
        Board(
            name: name,
            host: host,
            cells: cells.map { BoardCell(source: $0.source, lastKnownAgent: $0.snapshot) },
            pinnedRowHeights: pinnedRowHeights.isEmpty ? nil : pinnedRowHeights
        )
    }
}
