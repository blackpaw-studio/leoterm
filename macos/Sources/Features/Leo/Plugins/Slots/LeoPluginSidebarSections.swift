import Combine
import Foundation
import LeoKit

/// One plugin section as the sidebar lists it.
struct LeoPluginSidebarSectionEntry: Identifiable, Equatable {
    let pluginID: String
    let pluginName: String
    let sectionID: String
    let title: String

    var id: String { LeoSidebarPreferences.pluginSectionKey(plugin: pluginID, section: sectionID) }
    var slotKey: LeoPluginSlotKey { LeoPluginSlotKey(pluginID: pluginID, slot: .section(id: sectionID)) }
}

/// The sidebar's plugin sections: which are listed, which are open, and the
/// `activate` that fills one the first time it is opened. Collapse state
/// lives in `LeoSidebarPreferences` (collapsed unless opened); "Hide section"
/// is the registry's `hiddenSections`, which Settings → Plugins shows and
/// undoes.
@MainActor final class LeoPluginSidebarSections: ObservableObject {
    let host: any LeoPluginSlotHosting
    private let preferences: () -> LeoSidebarPreferences
    private let update: (LeoSidebarPreferences) -> Void
    private var requested: Set<String> = []
    private var subscription: AnyCancellable?

    /// `changes` fires when the plugin list or the preferences change, so
    /// views re-read `entries` and `isExpanded`.
    init(
        host: any LeoPluginSlotHosting,
        preferences: @escaping () -> LeoSidebarPreferences,
        update: @escaping (LeoSidebarPreferences) -> Void,
        changes: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.host = host
        self.preferences = preferences
        self.update = update
        subscription = changes.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// Visible sections, in plugin order then manifest order.
    var entries: [LeoPluginSidebarSectionEntry] {
        host.plugins.filter(\.isEnabled).flatMap { info -> [LeoPluginSidebarSectionEntry] in
            guard let manifest = info.manifest else { return [] }
            return manifest.contributes.sidebarSections
                .filter { !info.hiddenSections.contains($0.id) }
                .map { LeoPluginSidebarSectionEntry(pluginID: info.id, pluginName: info.name, sectionID: $0.id, title: $0.title) }
        }
    }

    func isExpanded(_ entry: LeoPluginSidebarSectionEntry) -> Bool {
        !preferences().isPluginSectionCollapsed(entry.id)
    }

    func toggle(_ entry: LeoPluginSidebarSectionEntry) {
        let expanding = !isExpanded(entry)
        update(preferences().setting(pluginSection: entry.id, collapsed: !expanding))
        if expanding { ensureLoaded(entry) }
    }

    /// Sends `activate` once if the section has nothing to show yet. A restart
    /// replays it, so a later look at a still-empty section doesn't resend.
    func ensureLoaded(_ entry: LeoPluginSidebarSectionEntry) {
        guard !requested.contains(entry.id), host.slots.state(entry.slotKey) == .loading else { return }
        requested.insert(entry.id)
        host.open(entry.slotKey.slot, plugin: entry.pluginID)
    }

    func hide(_ entry: LeoPluginSidebarSectionEntry) {
        try? host.setSection(entry.pluginID, section: entry.sectionID, hidden: true)
    }
}
