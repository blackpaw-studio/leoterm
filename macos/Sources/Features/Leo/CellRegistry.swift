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
    ///
    /// Entries are kept even after a surface is removed so an undo that restores
    /// the surface keeps its agent identity. Callers that care about what is
    /// actually on the board should use `agentNames(in:)`.
    var agentNames: [String] {
        sources.values.compactMap { if case .agent(let n) = $0 { return n } else { return nil } }
    }

    /// Names of agents backing one of `liveIDs` — i.e. actually on the board.
    func agentNames(in liveIDs: Set<UUID>) -> [String] {
        liveIDs.compactMap {
            if case .agent(let n) = source(for: $0) { return n } else { return nil }
        }
    }

    /// The live surface currently backing `agent`, if any.
    func id(forAgent agent: String, in liveIDs: Set<UUID>) -> UUID? {
        liveIDs.first { source(for: $0) == .agent(name: agent) }
    }

    /// True when `ids` is non-empty and every one of them is an agent cell.
    /// Agent cells detach rather than kill on close, so they skip confirmation.
    func containsOnlyAgents(_ ids: [UUID]) -> Bool {
        !ids.isEmpty && ids.allSatisfy { source(for: $0).isAgent }
    }
}
