import AppKit

/// The user's toolbar arrangement, kept in defaults across launches.
///
/// AppKit's own `autosavesConfiguration` stores a layout under the toolbar's
/// identifier, and each agent window's toolbar has an identifier of its own
/// (`LeoAgentToolbar`), so a layout saved that way would never load again.
/// The store keeps one list for every window instead.
///
/// The list holds what the user can arrange. The app-managed items (sidebar
/// toggle, separator, update pill, reset zoom) follow window state, so they
/// are never saved, and `restoredOrder` puts them back where the default
/// order has them.
struct LeoToolbarLayoutStore {
    static let key = "leo.toolbar.items"

    let defaults: UserDefaults

    func save(_ identifiers: [NSToolbarItem.Identifier]) {
        let kept = Self.deduplicated(identifiers.filter { Self.isKnown($0) && !LeoAgentToolbarItems.appManaged.contains($0) })
        defaults.set(kept.map(\.rawValue), forKey: Self.key)
    }

    /// The saved layout, cleaned up; the default order when nothing is saved.
    func restoredOrder() -> [NSToolbarItem.Identifier] {
        guard let saved = defaults.stringArray(forKey: Self.key) else { return LeoAgentToolbarItems.defaultOrder }
        let identifiers = saved.map { NSToolbarItem.Identifier($0) }
        let cleaned = Self.deduplicated(identifiers.filter { Self.isKnown($0) })
        return Self.restoringMissingItems(in: cleaned)
    }

    private static func isKnown(_ identifier: NSToolbarItem.Identifier) -> Bool {
        identifier == .flexibleSpace || LeoAgentToolbarItems.defaultOrder.contains(identifier)
    }

    /// Flexible spaces repeat; every other item appears once.
    private static func deduplicated(_ identifiers: [NSToolbarItem.Identifier]) -> [NSToolbarItem.Identifier] {
        var seen = Set<NSToolbarItem.Identifier>()
        return identifiers.filter { $0 == .flexibleSpace || seen.insert($0).inserted }
    }

    /// Puts each missing app-managed or immovable item back ahead of the
    /// earliest-placed item that follows it in the default order, or at the
    /// end when none is. Earliest in the list, not in the default order: with
    /// the user's toggles rearranged or removed, the update pill still lands
    /// ahead of the whole toggle group rather than between its toggles.
    private static func restoringMissingItems(in saved: [NSToolbarItem.Identifier]) -> [NSToolbarItem.Identifier] {
        let required = LeoAgentToolbarItems.defaultOrder.filter {
            LeoAgentToolbarItems.immovable.contains($0) || LeoAgentToolbarItems.appManaged.contains($0)
        }
        let order = LeoAgentToolbarItems.defaultOrder
        return required.reduce(saved) { list, identifier in
            guard !list.contains(identifier), let home = order.firstIndex(of: identifier) else { return list }
            let index = order[(home + 1)...].compactMap { list.firstIndex(of: $0) }.min() ?? list.count
            return Array(list[..<index]) + [identifier] + Array(list[index...])
        }
    }
}
