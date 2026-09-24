import Foundation

enum LeoSidebarReducers {
    static func rank(_ rows: [LeoAgentRow]) -> [LeoAgentRow] {
        rows.sorted { lhs, rhs in
            let lhsRank = rank(of: lhs)
            let rhsRank = rank(of: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if lhs.id.host != rhs.id.host { return String(describing: lhs.id.host) < String(describing: rhs.id.host) }
            return lhs.id.name < rhs.id.name
        }
    }

    /// The search filter: fuzzy-ranked over name and template (B-009).
    static func filter(_ rows: [LeoAgentRow], query: String) -> [LeoAgentRow] {
        LeoFuzzyMatcher.rank(rows, query: query)
    }

    static func mergeActivity(_ rows: [LeoAgentRow], activityByName: [String: LeoSidebarActivity]) -> [LeoAgentRow] {
        rows.map { row in
            guard let overlay = activityByName[row.name] else { return row }
            // A stopped agent keeps no live activity, only when it was last active.
            let isStopped = row.status == .stopped
            return LeoAgentRow(
                host: row.host, name: row.name, template: row.template, status: row.status,
                activity: isStopped ? row.activity : overlay.activity, actionDetail: isStopped ? row.actionDetail : overlay.detail,
                workspace: row.workspace, repo: row.repo, lastActivityAt: overlay.lastActivityAt
            )
        }
    }

    static func applyListResult(_ snapshot: LeoSidebarSnapshot, result: [LeoAgentRow], generation: Int) -> LeoSidebarSnapshot {
        guard generation == snapshot.generation else { return snapshot }
        return LeoSidebarSnapshot(rows: result, connectivity: .connected, generation: generation, listRefreshSucceeded: true)
    }

    private static func rank(of row: LeoAgentRow) -> Int {
        switch row.status {
        case .running: row.activity == .working ? 0 : 1
        case .starting: 2
        case .stopped: 3
        case .unknown: 4
        }
    }
}
