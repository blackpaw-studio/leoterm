import Foundation
import LeoKit

/// The harness (claude, codex, …) running each agent on the selected host.
/// `/agents/list` doesn't carry it; `/state` does. Replaced whole by each
/// applied `/state`. Keyed by name.
struct LeoAgentHarnessIndex: Equatable, Sendable {
    static let empty = LeoAgentHarnessIndex(byName: [:])

    let byName: [String: String]

    init(byName: [String: String]) {
        self.byName = byName
    }

    init(state: [LeoObservedAgent]) {
        byName = Dictionary(
            state.compactMap { agent in agent.harness.flatMap { $0.isEmpty ? nil : (agent.name, $0) } },
            uniquingKeysWith: { _, last in last }
        )
    }

    subscript(name: String) -> String? { byName[name] }
}

extension LeoSidebarSnapshot {
    /// Rows carrying the harness `/state` reported for them.
    func overlayingHarness(_ index: LeoAgentHarnessIndex) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows.map { $0.withHarness(index[$0.name]) }, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
