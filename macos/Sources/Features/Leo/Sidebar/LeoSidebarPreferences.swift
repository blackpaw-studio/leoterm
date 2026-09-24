import Foundation

/// Agents ▸ Sort By (B-010).
enum LeoSidebarSortOrder: String, Codable, CaseIterable, Sendable {
    /// Newest daemon-reported activity first; unknown times after, by name.
    case lastActivity
    case name
}

/// The sidebar's remembered arrangement: sort order, pinned agents (keyed
/// by host + name, kept even while the agent is absent) and each host's
/// collapsed sections.
struct LeoSidebarPreferences: Codable, Equatable, Sendable {
    var sortOrder: LeoSidebarSortOrder
    var pinned: Set<LeoAgentRow.ID>
    var collapsed: [LeoHostID: Set<String>]

    init(sortOrder: LeoSidebarSortOrder = .lastActivity, pinned: Set<LeoAgentRow.ID> = [], collapsed: [LeoHostID: Set<String>] = [:]) {
        self.sortOrder = sortOrder
        self.pinned = pinned
        self.collapsed = collapsed
    }

    /// Lenient: a field that's missing or unreadable falls back to its
    /// default instead of discarding the others.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LeoSidebarPreferences()
        sortOrder = (try? container.decodeIfPresent(LeoSidebarSortOrder.self, forKey: .sortOrder)) ?? defaults.sortOrder
        pinned = (try? container.decodeIfPresent(Set<LeoAgentRow.ID>.self, forKey: .pinned)) ?? defaults.pinned
        collapsed = (try? container.decodeIfPresent([LeoHostID: Set<String>].self, forKey: .collapsed)) ?? defaults.collapsed
    }

    static func decode(_ data: Data?) -> LeoSidebarPreferences {
        guard let data, let decoded = try? JSONDecoder().decode(LeoSidebarPreferences.self, from: data) else { return LeoSidebarPreferences() }
        return decoded
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    func isCollapsed(_ sectionID: String, host: LeoHostID) -> Bool {
        collapsed[host]?.contains(sectionID) ?? false
    }

    func with(sortOrder: LeoSidebarSortOrder) -> LeoSidebarPreferences {
        LeoSidebarPreferences(sortOrder: sortOrder, pinned: pinned, collapsed: collapsed)
    }

    func togglingPin(_ id: LeoAgentRow.ID) -> LeoSidebarPreferences {
        LeoSidebarPreferences(sortOrder: sortOrder, pinned: pinned.symmetricDifference([id]), collapsed: collapsed)
    }

    func setting(_ sectionID: String, collapsed isCollapsed: Bool, host: LeoHostID) -> LeoSidebarPreferences {
        let current = collapsed[host] ?? []
        let updated = isCollapsed ? current.union([sectionID]) : current.subtracting([sectionID])
        var hosts = collapsed
        hosts[host] = updated.isEmpty ? nil : updated
        return LeoSidebarPreferences(sortOrder: sortOrder, pinned: pinned, collapsed: hosts)
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
