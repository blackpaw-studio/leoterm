import Foundation
import LeoKit

/// The selected host's agent briefs: replaced whole by each applied `/state`,
/// set per agent by `agent_brief`, emptied by `brief_config_changed(false)`.
struct LeoAgentBriefIndex: Equatable, Sendable {
    static let empty = LeoAgentBriefIndex(byName: [:])

    let byName: [String: LeoAgentBrief]

    init(byName: [String: LeoAgentBrief]) {
        self.byName = byName
    }

    /// What one `/state` reported; an agent it reports none for has none.
    init(state: [LeoObservedAgent]) {
        byName = Dictionary(state.compactMap { agent in agent.brief.map { (agent.name, $0) } }, uniquingKeysWith: { _, last in last })
    }

    /// The event carries the whole brief: nil means it was cleared.
    func setting(_ name: String, to brief: LeoAgentBrief?) -> LeoAgentBriefIndex {
        var next = byName
        next[name] = brief
        return LeoAgentBriefIndex(byName: next)
    }

    subscript(name: String) -> LeoAgentBrief? { byName[name] }
}
