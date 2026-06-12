import Foundation

/// A snapshot of the agent a cell was attached to, kept so a dead cell can be
/// labeled and offered for respawn even when the agent is gone from the daemon.
struct AgentSnapshot: Codable, Equatable, Sendable {
    let name: String
    let repo: String
}

/// Whether a board cell is currently backed by a live source.
enum CellLiveness: Equatable, Sendable { case attached, dead }

/// One cell on a board. `liveness` is transient (recomputed on restore), not persisted.
struct BoardCell: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: CellSource
    var lastKnownAgent: AgentSnapshot?
    var liveness: CellLiveness

    init(id: UUID = UUID(), source: CellSource, lastKnownAgent: AgentSnapshot? = nil, liveness: CellLiveness = .attached) {
        self.id = id
        self.source = source
        self.lastKnownAgent = lastKnownAgent
        self.liveness = liveness
    }

    enum CodingKeys: String, CodingKey { case id, source, lastKnownAgent }
    // liveness is intentionally not encoded; it is derived on reconcile.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(CellSource.self, forKey: .source)
        lastKnownAgent = try c.decodeIfPresent(AgentSnapshot.self, forKey: .lastKnownAgent)
        liveness = .attached
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(lastKnownAgent, forKey: .lastKnownAgent)
    }
}

/// A curated set of agents/cells, mapped to a Ghostty tab.
struct Board: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    /// The leo host this board's agents live on. `localhost` (the default)
    /// targets the local daemon; a remote name routes through an SSH forward.
    var host: String
    var cells: [BoardCell]

    init(id: UUID = UUID(), name: String, host: String = LeoHost.localhostName, cells: [BoardCell]) {
        self.id = id
        self.name = name
        self.host = host
        self.cells = cells
    }

    enum CodingKeys: String, CodingKey { case id, name, host, cells }

    // Custom decode so boards persisted before the `host` field default to
    // localhost instead of failing to decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? LeoHost.localhostName
        cells = try c.decode([BoardCell].self, forKey: .cells)
    }

    /// Recompute each cell's liveness against the live daemon roster: an agent
    /// cell is `.dead` if no running agent with its name exists; pty cells are
    /// always `.attached`.
    func reconciled(against liveAgents: [Agent]) -> Board {
        let running = Set(liveAgents.filter { $0.status == .running }.map(\.name))
        let newCells = cells.map { cell -> BoardCell in
            var c = cell
            switch cell.source {
            case .pty:
                c.liveness = .attached
            case .agent(let name):
                c.liveness = running.contains(name) ? .attached : .dead
            }
            return c
        }
        return Board(id: id, name: name, host: host, cells: newCells)
    }
}
