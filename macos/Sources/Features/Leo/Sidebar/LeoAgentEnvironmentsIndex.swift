import Foundation

/// The selected host's effective environment names per agent (B-283):
/// replaced whole by each applied `/state`, patched by events that carry
/// the fields. Keyed by name: a set applies to whichever incarnation is
/// live, and the next `/state` restates it anyway.
struct LeoAgentEnvironmentsIndex: Equatable, Sendable {
    static let empty = LeoAgentEnvironmentsIndex(byName: [:])

    let byName: [String: LeoAgentEnvironments]

    init(byName: [String: LeoAgentEnvironments]) {
        self.byName = byName
    }

    /// What one `/state` reported; an agent it reports none for has none.
    init(state: [LeoObservedAgent]) {
        byName = Dictionary(state.compactMap { agent in agent.environments.map { (agent.name, $0) } }, uniquingKeysWith: { _, last in last })
    }

    func patching(_ name: String, with patch: LeoAgentEnvironmentsPatch) -> LeoAgentEnvironmentsIndex {
        var next = byName
        next[name] = patch.applied(to: byName[name])
        return LeoAgentEnvironmentsIndex(byName: next)
    }

    subscript(name: String) -> LeoAgentEnvironments? { byName[name] }
}
