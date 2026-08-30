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

    /// What the controller should do with one saved cell on restore.
    enum RestoreAction: Equatable {
        /// Materialize a live surface for this source.
        case live(CellSource)
        /// Render a dead placeholder built from the last known snapshot.
        case dead(AgentSnapshot)
        /// Nothing to do: already on the board, or a dead cell we cannot label.
        case skip
    }

    /// Decide what to do with each saved cell, in board order.
    ///
    /// Dead cells without a snapshot are skipped rather than attached: there is
    /// no agent behind them, so a surface would immediately exit. Dead cells are
    /// deduplicated by agent name, and agents already on the board are skipped
    /// so an explicit re-restore does not duplicate cells.
    static func restoreActions(
        board: Board,
        liveAgents: [Agent],
        alreadyOnBoard: Set<String>
    ) -> [RestoreAction] {
        var seenDead: Set<String> = []
        return restorePlan(board: board, liveAgents: liveAgents).map { cell in
            if cell.isDead {
                guard let snapshot = cell.snapshot, seenDead.insert(snapshot.name).inserted else {
                    return .skip
                }
                return .dead(snapshot)
            }
            // Only agent cells are ever persisted, so in practice every live
            // action here is an agent; the source is passed through unchanged.
            if case .agent(let name) = cell.source, alreadyOnBoard.contains(name) { return .skip }
            return .live(cell.source)
        }
    }

    /// The parts of a live daemon roster entry that a snapshot cares about.
    struct LiveAgentInfo: Equatable, Sendable {
        let repo: String
        let template: String?
    }

    /// Merge what the live roster knows about an agent with what was persisted
    /// last time. The roster is authoritative when it has a value, but it is
    /// often unavailable (daemon offline, sidebar retargeted to another host),
    /// and losing repo/template there would destroy respawn-prefill data.
    static func snapshot(
        forAgent name: String,
        live: LiveAgentInfo?,
        previous: AgentSnapshot?
    ) -> AgentSnapshot {
        let liveRepo = (live?.repo).flatMap { $0.isEmpty ? nil : $0 }
        let repo = liveRepo ?? previous?.repo ?? ""
        let template = live?.template ?? previous?.template
        return AgentSnapshot(name: name, repo: repo, template: template, branch: previous?.branch)
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
