import Foundation

/// The daemon's `/state` snapshot: every agent, plus its dispatches
/// (leo >= 0.35, `dispatch_tree`). The daemon omits an empty `dispatches`
/// (`omitempty`), so a missing key reads as none; only the hello feature
/// list tells "no dispatch source" apart from "none running".
struct LeoObservedState: Decodable, Equatable, Sendable {
    let agents: [LeoObservedAgent]
    /// Live dispatches plus those that ended within the daemon's linger
    /// window; a malformed entry is dropped, never fatal.
    let dispatches: [LeoDispatch]
    /// `meta.seq` (`state_seq`): the snapshot reflects every event with a
    /// seq up to this one, and may already reflect later ones. Absent on
    /// an older daemon.
    let seq: Int?

    init(agents: [LeoObservedAgent], dispatches: [LeoDispatch] = [], seq: Int? = nil) {
        self.agents = agents
        self.dispatches = dispatches
        self.seq = seq
    }

    enum CodingKeys: String, CodingKey { case agents, dispatches, meta }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decode([LeoObservedAgent].self, forKey: .agents)
        dispatches = ((try? container.decodeIfPresent(LeoLenientDispatches.self, forKey: .dispatches)) ?? nil)?.dispatches ?? []
        struct Meta: Decodable { let seq: Int? }
        seq = ((try? container.decodeIfPresent(Meta.self, forKey: .meta)) ?? nil)?.seq
    }
}
