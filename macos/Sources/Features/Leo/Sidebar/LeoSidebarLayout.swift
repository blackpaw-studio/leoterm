import Foundation

/// B-010: how the sidebar arranges rows -- a Pinned section on top, then
/// one section per status (Running, Starting, Stopped, others), each in
/// the chosen sort order, with collapsed sections reduced to their header.
///
/// While the search filter is non-empty the arrangement is B-009's
/// instead: fuzzy-ranked matches grouped by status in rank order, nothing
/// collapsed and no Pinned section, so the first row shown is always the
/// best match that Return picks.
enum LeoSidebarLayout {
    static let pinnedSectionID = "pinned"

    /// Last Activity: newest snapshot time first, ties and rows without one
    /// by name -- unless none of these rows has a time (no snapshot yet, or the
    /// daemon reports none), when the daemon's order is kept rather than a
    /// time invented (D-073, D-082).
    static func sorted(_ rows: [LeoAgentRow], by order: LeoSidebarSortOrder) -> [LeoAgentRow] {
        switch order {
        case .name:
            return rows.sorted(by: nameAscending)
        case .lastActivity:
            guard rows.contains(where: { activityTime($0) != nil }) else { return rows }
            return rows.sorted { lhs, rhs in newerFirst(activityTime(lhs), activityTime(rhs)) ?? nameAscending(lhs, rhs) }
        }
    }

    /// The sort key: `last_activity_at` from the identity-checked `/state`
    /// snapshot attached to this row (D-074, D-075). Never a live
    /// `agent_activity` event, so events alone don't reorder rows.
    static func activityTime(_ row: LeoAgentRow) -> Date? { row.metadata?.lastActiveAt }

    static func sections(rows: [LeoAgentRow], query: String, preferences: LeoSidebarPreferences, host: LeoHostID) -> [LeoSidebarSection] {
        if isFiltering(query) { return LeoSidebarSectioning.sections(for: filtered(rows, query: query, order: preferences.sortOrder)) }
        let pinned = sorted(rows.filter { preferences.pinned.contains($0.id) }, by: preferences.sortOrder)
        let pinnedSection = pinned.isEmpty ? [] : [LeoSidebarSection(
            id: pinnedSectionID, title: "Pinned", rows: pinned,
            isCollapsed: preferences.isCollapsed(pinnedSectionID, host: host)
        )]
        let statusSections = statusGroups(rows.filter { !preferences.pinned.contains($0.id) }, order: preferences.sortOrder).map { key, rows in
            LeoSidebarSection(
                id: key, title: LeoSidebarSectioning.title(for: key), rows: rows,
                isCollapsed: preferences.isCollapsed(key, host: host)
            )
        }
        return pinnedSection + statusSections
    }

    /// Rows a person can see, top to bottom: with a filter, the ranked
    /// matches (B-009); without, every row outside a collapsed section.
    static func visibleRows(rows: [LeoAgentRow], query: String, preferences: LeoSidebarPreferences, host: LeoHostID) -> [LeoAgentRow] {
        if isFiltering(query) { return filtered(rows, query: query, order: preferences.sortOrder) }
        return sections(rows: rows, query: "", preferences: preferences, host: host)
            .filter { !$0.isCollapsed }
            .flatMap(\.rows)
    }

    /// The unfiltered display order, collapsed sections included (Jump).
    static func orderedRows(_ rows: [LeoAgentRow], preferences: LeoSidebarPreferences) -> [LeoAgentRow] {
        sections(rows: rows, query: "", preferences: preferences, host: .local).flatMap(\.rows)
    }

    /// The section a row is shown in when nothing is filtered.
    static func sectionID(of row: LeoAgentRow, preferences: LeoSidebarPreferences) -> String {
        preferences.pinned.contains(row.id) ? pinnedSectionID : LeoSidebarSectioning.sectionKey(for: row.status)
    }

    static func isFiltering(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func filtered(_ rows: [LeoAgentRow], query: String, order: LeoSidebarSortOrder) -> [LeoAgentRow] {
        LeoSidebarReducers.filter(statusGroups(rows, order: order).flatMap(\.rows), query: query)
    }

    /// Status groups in rank order (unrecognised statuses last, by key),
    /// each sorted.
    private static func statusGroups(_ rows: [LeoAgentRow], order: LeoSidebarSortOrder) -> [(key: String, rows: [LeoAgentRow])] {
        Dictionary(grouping: rows) { LeoSidebarSectioning.sectionKey(for: $0.status) }
            .map { (key: $0.key, rows: sorted($0.value, by: order)) }
            .sorted { lhs, rhs in
                let lhsRank = statusRank(lhs.key)
                let rhsRank = statusRank(rhs.key)
                return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.key < rhs.key
            }
    }

    private static func statusRank(_ key: String) -> Int {
        switch key {
        case "running": 0
        case "starting": 1
        case "stopped": 2
        default: 3
        }
    }

    /// Nil when the times don't decide it: equal, or both unknown.
    private static func newerFirst(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs == rhs ? nil : lhs > rhs
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): nil
        }
    }

    private static func nameAscending(_ lhs: LeoAgentRow, _ rhs: LeoAgentRow) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        if lhs.host != rhs.host { return String(describing: lhs.host) < String(describing: rhs.host) }
        return lhs.name < rhs.name
    }
}
