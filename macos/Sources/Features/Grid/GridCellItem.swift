import Foundation

/// A renderable cell in the grid: either a live terminal surface or a dead
/// placeholder for an agent that is no longer running (restored from a board).
/// Both ids are UUID, so the existing UUID-keyed hover/pin/emphasis logic and
/// GridLayout work unchanged.
enum GridCellItem: Identifiable {
    case surface(Ghostty.SurfaceView)
    case dead(DeadCell)

    var id: UUID {
        switch self {
        case .surface(let surface): return surface.id
        case .dead(let dead): return dead.id
        }
    }
}

/// Data for a dead grid placeholder (an agent that was on the board but is gone).
struct DeadCell: Identifiable, Equatable {
    let id: UUID
    let snapshot: AgentSnapshot
}
