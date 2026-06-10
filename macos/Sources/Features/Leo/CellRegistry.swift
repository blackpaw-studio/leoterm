import Foundation

/// Maps a surface's stable ID to the `CellSource` that backs it, so boards can
/// be persisted/restored and the sidebar can answer "is this agent on the board?".
/// Unknown IDs resolve to `.pty` (a plain shell), matching how surfaces created
/// outside the Leo flow behave.
struct CellRegistry {
    private var sources: [UUID: CellSource] = [:]

    func source(for id: UUID) -> CellSource { sources[id] ?? .pty }
    mutating func record(id: UUID, source: CellSource) { sources[id] = source }
    mutating func forget(id: UUID) { sources.removeValue(forKey: id) }

    /// Names of agents currently backing a cell.
    var agentNames: [String] {
        sources.values.compactMap { if case .agent(let n) = $0 { return n } else { return nil } }
    }
}
