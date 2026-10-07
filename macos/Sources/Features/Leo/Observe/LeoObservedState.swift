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

    init(agents: [LeoObservedAgent], dispatches: [LeoDispatch] = []) {
        self.agents = agents
        self.dispatches = dispatches
    }

    enum CodingKeys: String, CodingKey { case agents, dispatches }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decode([LeoObservedAgent].self, forKey: .agents)
        dispatches = ((try? container.decodeIfPresent(LeoLenientDispatches.self, forKey: .dispatches)) ?? nil)?.dispatches ?? []
    }
}
