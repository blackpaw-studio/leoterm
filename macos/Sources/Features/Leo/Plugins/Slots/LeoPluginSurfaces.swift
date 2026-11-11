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
    private var visibleCounts: [LeoPluginSlotKey: Int] = [:]

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

    func slotContent(for ref: LeoPluginViewRef) -> LeoPluginSlotContent {
        guard let manager else { return .notice(LeoPluginSlotContent.unavailableNotice) }
        let available = viewEntries().contains { $0.pluginID == ref.pluginID && $0.viewID == ref.viewID }
        return LeoPluginSlotContent.resolve(
            state: manager.slots.state(ref.slotKey), pushed: manager.slots.pushed[ref.slotKey] ?? [], pluginAvailable: available)
    }

    func open(_ ref: LeoPluginViewRef) { manager?.open(ref.slot, plugin: ref.pluginID) }
    func retry(_ ref: LeoPluginViewRef) { manager?.retry(ref.slotKey) }
    func pop(_ ref: LeoPluginViewRef) { manager?.slots.pop(ref.slotKey) }

    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?, in ref: LeoPluginViewRef) {
        manager?.perform(action, plugin: ref.pluginID, slot: ref.slot, gesture: gesture)
    }

    func setVisible(_ ref: LeoPluginViewRef, _ visible: Bool) {
        let key = ref.slotKey
        visibleCounts[key, default: 0] += visible ? 1 : -1
        if (visibleCounts[key] ?? 0) <= 0 { visibleCounts[key] = nil }
        let anyVisible = visibleCounts.keys.contains { $0.pluginID == ref.pluginID }
        manager?.setSlotVisible(plugin: ref.pluginID, visible: anyVisible)
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
