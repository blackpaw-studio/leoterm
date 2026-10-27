import Foundation
import LeoKit

/// The selected host's resolved agent appearance: replaced whole by each
/// applied `/state`, set per agent by `agent_appearance_changed`. Keyed by
/// name, like the environments index; the next `/state` restates it anyway.
struct LeoAgentAppearanceIndex: Equatable, Sendable {
    static let empty = LeoAgentAppearanceIndex(byName: [:])

    let byName: [String: LeoAgentAppearance]

    init(byName: [String: LeoAgentAppearance]) {
        self.byName = byName
    }

    /// What one `/state` reported; an agent it reports none for has none.
    init(state: [LeoObservedAgent]) {
        byName = Dictionary(state.compactMap { agent in agent.appearance.map { (agent.name, $0) } }, uniquingKeysWith: { _, last in last })
    }

    /// The event carries the whole resolved value: nil means nothing is set.
    func setting(_ name: String, to appearance: LeoAgentAppearance?) -> LeoAgentAppearanceIndex {
        var next = byName
        next[name] = appearance
        return LeoAgentAppearanceIndex(byName: next)
    }

    subscript(name: String) -> LeoAgentAppearance? { byName[name] }
}
