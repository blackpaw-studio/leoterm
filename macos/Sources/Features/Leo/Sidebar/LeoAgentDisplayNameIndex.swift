import Foundation
import LeoKit

/// The selected host's daemon `display_name` per agent. `/agents/list` (the
/// source of the rows) doesn't carry it; `/state` and `agent.spawned` do.
/// Replaced whole by each applied `/state` and patched by a spawn, so an agent
/// that reports none (or was recreated without one) has none. Keyed by name.
struct LeoAgentDisplayNameIndex: Equatable, Sendable {
    static let empty = LeoAgentDisplayNameIndex(byName: [:])

    let byName: [String: String]

    init(byName: [String: String]) {
        self.byName = byName
    }

    init(state: [LeoObservedAgent]) {
        byName = Dictionary(
            state.compactMap { agent in agent.daemonDisplayName.map { (agent.name, $0) } },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// `name` as a freshly (re)spawned incarnation reported it.
    func spawning(_ name: String, displayName: String?) -> LeoAgentDisplayNameIndex {
        var next = byName
        next[name] = displayName
        return LeoAgentDisplayNameIndex(byName: next)
    }

    subscript(name: String) -> String? { byName[name] }
}
