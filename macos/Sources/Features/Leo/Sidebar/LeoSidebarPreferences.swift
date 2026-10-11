import Foundation

/// Agents ▸ Sort By (B-010).
enum LeoSidebarSortOrder: String, Codable, CaseIterable, Sendable {
    /// Newest daemon-reported activity first; unknown times after, by name.
    case lastActivity
    case name
}

/// Agents ▸ Group By: the default status sections, or the opt-in
/// attention sections (Needs You / Working / Finished / Idle & Stopped).
enum LeoSidebarGroupBy: String, Codable, CaseIterable, Sendable {
    case status
    case attention
}

/// The sidebar's remembered arrangement: sort order, grouping, pinned
/// agents (keyed by host + name, kept even while the agent is absent) and
/// each host's collapsed sections. A section that starts collapsed
/// (`LeoSidebarLayout.defaultCollapsedSectionIDs`) is remembered open in
/// `expanded` instead.
struct LeoSidebarPreferences: Codable, Equatable, Sendable {
    var sortOrder: LeoSidebarSortOrder
    var groupBy: LeoSidebarGroupBy
    var pinned: Set<LeoAgentRow.ID>
    var collapsed: [LeoHostID: Set<String>]
    var expanded: [LeoHostID: Set<String>]

    init(
        sortOrder: LeoSidebarSortOrder = .lastActivity, groupBy: LeoSidebarGroupBy = .status,
        pinned: Set<LeoAgentRow.ID> = [], collapsed: [LeoHostID: Set<String>] = [:],
        expanded: [LeoHostID: Set<String>] = [:]
    ) {
        self.sortOrder = sortOrder
        self.groupBy = groupBy
        self.pinned = pinned
        self.collapsed = collapsed
        self.expanded = expanded
    }

    /// Lenient: a field that's missing or unreadable falls back to its
    /// default instead of discarding the others.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LeoSidebarPreferences()
        sortOrder = (try? container.decodeIfPresent(LeoSidebarSortOrder.self, forKey: .sortOrder)) ?? defaults.sortOrder
        groupBy = (try? container.decodeIfPresent(LeoSidebarGroupBy.self, forKey: .groupBy)) ?? defaults.groupBy
        pinned = (try? container.decodeIfPresent(Set<LeoAgentRow.ID>.self, forKey: .pinned)) ?? defaults.pinned
        collapsed = (try? container.decodeIfPresent([LeoHostID: Set<String>].self, forKey: .collapsed)) ?? defaults.collapsed
        expanded = (try? container.decodeIfPresent([LeoHostID: Set<String>].self, forKey: .expanded)) ?? defaults.expanded
    }

    static func decode(_ data: Data?) -> LeoSidebarPreferences {
        guard let data, let decoded = try? JSONDecoder().decode(LeoSidebarPreferences.self, from: data) else { return LeoSidebarPreferences() }
        return decoded
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    func isCollapsed(_ sectionID: String, host: LeoHostID) -> Bool {
        if collapsed[host]?.contains(sectionID) == true { return true }
        guard LeoSidebarLayout.defaultCollapsedSectionIDs.contains(sectionID) else { return false }
        return expanded[host]?.contains(sectionID) != true
    }

    func with(sortOrder: LeoSidebarSortOrder) -> LeoSidebarPreferences {
        var updated = self
        updated.sortOrder = sortOrder
        return updated
    }

    func with(groupBy: LeoSidebarGroupBy) -> LeoSidebarPreferences {
        var updated = self
        updated.groupBy = groupBy
        return updated
    }

    func togglingPin(_ id: LeoAgentRow.ID) -> LeoSidebarPreferences {
        var updated = self
        updated.pinned = pinned.symmetricDifference([id])
        return updated
    }

    func setting(_ sectionID: String, collapsed isCollapsed: Bool, host: LeoHostID) -> LeoSidebarPreferences {
        var updated = self
        if LeoSidebarLayout.defaultCollapsedSectionIDs.contains(sectionID) {
            updated.expanded = Self.updating(expanded, host: host, sectionID, contains: !isCollapsed)
        } else {
            updated.collapsed = Self.updating(collapsed, host: host, sectionID, contains: isCollapsed)
        }
        return updated
    }

    private static func updating(
        _ hosts: [LeoHostID: Set<String>], host: LeoHostID, _ sectionID: String, contains: Bool
    ) -> [LeoHostID: Set<String>] {
        let current = hosts[host] ?? []
        let updated = contains ? current.union([sectionID]) : current.subtracting([sectionID])
        var result = hosts
        result[host] = updated.isEmpty ? nil : updated
        return result
    }
}

/// Where `LeoSidebarModel` keeps its preferences; injected so tests use an
/// isolated in-memory store.
protocol LeoSidebarPreferencesStore: AnyObject {
    func load() -> LeoSidebarPreferences
    func save(_ preferences: LeoSidebarPreferences)
}

final class LeoInMemorySidebarPreferencesStore: LeoSidebarPreferencesStore {
    private var stored: LeoSidebarPreferences

    init(_ preferences: LeoSidebarPreferences = LeoSidebarPreferences()) { stored = preferences }

    func load() -> LeoSidebarPreferences { stored }
    func save(_ preferences: LeoSidebarPreferences) { stored = preferences }
}

final class LeoUserDefaultsSidebarPreferencesStore: LeoSidebarPreferencesStore {
    static let key = "leo.sidebarPreferences"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> LeoSidebarPreferences { LeoSidebarPreferences.decode(defaults.data(forKey: Self.key)) }

    func save(_ preferences: LeoSidebarPreferences) {
        guard let data = preferences.encoded() else { return }
        defaults.set(data, forKey: Self.key)
    }
}
