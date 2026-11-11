import Combine
import Foundation
import LeoKit
import SwiftUI

/// What the sidebar, the menus and the row panes read the plugin system
/// through: slot 1 (agent views) and slot 2 (row accessories). One per app,
/// made at launch and attached to the manager once the plugin system starts,
/// so windows opened earlier still pick it up.
@MainActor final class LeoPluginSurfaces: ObservableObject, LeoPluginPaneHosting {
    private(set) var manager: LeoPluginManager?
    /// The top-level agents a plugin's accessories are asked for.
    private let agents: () -> [LeoPluginAgentRef]
    private var subscriptions: Set<AnyCancellable> = []
    private var visibility = LeoPluginSlotVisibility()

    init(agents: @escaping () -> [LeoPluginAgentRef] = { [] }) {
        self.agents = agents
    }

    func attach(_ manager: LeoPluginManager) {
        guard self.manager == nil else { return }
        self.manager = manager
        manager.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        manager.slots.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        // A plugin that starts, or is enabled, after the agents were listed still gets asked.
        manager.$plugins.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reconcileAccessories() }.store(in: &subscriptions)
    }

    // MARK: Slot 1: views

    func viewEntries() -> [LeoPluginViewEntry] {
        manager.map { LeoPluginViewEntries.make(from: $0.plugins) } ?? []
    }

    var changes: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }

    func content(for key: LeoPluginSlotKey) -> LeoPluginSlotContent {
        guard let manager else { return .notice(LeoPluginSlotContent.unavailableNotice) }
        return LeoPluginSlotContent.resolve(
            state: manager.slots.state(key), pushed: manager.slots.pushed[key] ?? [], pluginAvailable: isAvailable(key))
    }

    /// Whether the plugin still contributes this slot and is on.
    private func isAvailable(_ key: LeoPluginSlotKey) -> Bool {
        guard let manager, let plugin = manager.plugins.first(where: { $0.id == key.pluginID }),
              plugin.isEnabled, let contributes = plugin.manifest?.contributes
        else { return false }
        switch key.slot {
        case .view(let viewID, _): return viewEntries().contains { $0.pluginID == key.pluginID && $0.viewID == viewID }
        case .section(let id): return contributes.sidebarSections.contains { $0.id == id }
        case .palette(let id): return contributes.commands.contains { $0.id == id }
        case .accessory(let id, _): return contributes.rowAccessories.contains { $0.id == id }
        }
    }

    func open(_ ref: LeoPluginViewRef) { manager?.open(ref.slot, plugin: ref.pluginID) }
    func retry(_ key: LeoPluginSlotKey) { manager?.retry(key) }
    func pop(_ key: LeoPluginSlotKey) { manager?.slots.pop(key) }

    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?, in key: LeoPluginSlotKey) {
        manager?.perform(action, plugin: key.pluginID, slot: key.slot, gesture: gesture)
    }

    func setVisible(_ key: LeoPluginSlotKey, _ visible: Bool) {
        guard let now = visibility.set(key, visible: visible) else { return }
        manager?.setSlotVisible(plugin: key.pluginID, visible: now)
    }

    // MARK: Slot 2: row accessories

    /// What a row draws: the plugins' accessories for that agent, capped, in plugin-id order.
    func accessoryLayout(host: LeoHostID, agent: String) -> LeoPluginAccessoryLayout {
        guard let manager else { return LeoPluginAccessoryLayout(entries: []) }
        let ref = LeoPluginAgentRef(machine: host.displayName, name: agent)
        let entries = manager.plugins.flatMap { plugin -> [LeoPluginAccessoryLayout.Entry] in
            (plugin.manifest?.contributes.rowAccessories ?? []).map {
                .init(
                    pluginID: plugin.id, pluginName: plugin.name,
                    state: manager.slots.state(pluginID: plugin.id, slot: .accessory(id: $0.id, agent: ref)))
            }
        }
        return LeoPluginAccessoryLayout(entries: entries)
    }

    /// Asks each plugin that contributes an accessory for every agent it hasn't
    /// been asked about (new agents, a plugin that just started). Cheap to call
    /// often: a slot the plugin already knows is skipped.
    func reconcileAccessories() {
        guard let manager else { return }
        let refs = agents()
        for plugin in manager.plugins where Self.runs(plugin) {
            let known = Set(manager.slots.slots(of: plugin.id))
            for contribution in plugin.manifest?.contributes.rowAccessories ?? [] {
                for ref in refs {
                    let slot = LeoPluginSlotID.accessory(id: contribution.id, agent: ref)
                    if !known.contains(slot) { manager.open(slot, plugin: plugin.id) }
                }
            }
        }
    }

    private static func runs(_ plugin: LeoPluginInfo) -> Bool {
        guard plugin.isEnabled, plugin.manifest != nil else { return false }
        switch plugin.state {
        case .running, .restarting: return true
        case .stoppedByUser, .needsApproval, .disabled, .refused: return false
        }
    }
}

private struct LeoPluginSurfacesKey: EnvironmentKey {
    static let defaultValue: LeoPluginSurfaces? = nil
}

extension EnvironmentValues {
    /// Nil (no plugin chrome) until the app supplies the plugin surfaces.
    var leoPluginSurfaces: LeoPluginSurfaces? {
        get { self[LeoPluginSurfacesKey.self] }
        set { self[LeoPluginSurfacesKey.self] = newValue }
    }
}
