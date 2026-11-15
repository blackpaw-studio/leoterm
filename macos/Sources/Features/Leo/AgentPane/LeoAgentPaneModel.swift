import Combine
import Foundation
import LeoKit

/// The agent pane's live model, one per window: the remembered state
/// (expanded, selected tab, height; shared app-wide through the store), the
/// tabs (the built-in Terminal, when on, then what the plugins contribute),
/// and the agent the window shows. It opens the pane slots plugins render
/// into; the views mount what `mounts` names, and those hosts report
/// visibility through the plugin surfaces. Without a plugin system it still
/// works: the Terminal is the only tab.
@MainActor final class LeoAgentPaneModel: ObservableObject {
    @Published private(set) var state: LeoAgentPaneState
    @Published private(set) var tabs: [LeoAgentPaneTab] = []
    /// The agent the window shows; nil for a terminal or nothing selected.
    @Published private(set) var agent: LeoAgentPaneAgent?

    let surfaces: LeoPluginSurfaces?
    /// What the Terminal tab runs on; set by the window's session once it has a
    /// controller. Without it the Terminal tab draws nothing.
    var drawer: LeoDrawerEnvironment?
    private let store: LeoAgentPaneStateStore
    private let settings: LeoBuiltInPaneSettings
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?

    init(surfaces: LeoPluginSurfaces?, settings: LeoBuiltInPaneSettings, store: LeoAgentPaneStateStore) {
        self.surfaces = surfaces
        self.settings = settings
        self.store = store
        state = store.load()
        // `changes` fires before a change lands; the hop reads the new plugins.
        subscription = surfaces?.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refreshTabs() } }
        // The published value is the new one (reading the property here would still see the old).
        settingsSubscription = settings.$showsTerminalTab.dropFirst()
            .sink { [weak self] in self?.refreshTabs(showsTerminal: $0) }
        refreshTabs()
    }

    /// Nothing is drawn without an agent and at least one tab.
    var isShown: Bool { Self.isShown(agent: agent, tabs: tabs) }

    static func isShown(agent: LeoAgentPaneAgent?, tabs: [LeoAgentPaneTab]) -> Bool { agent != nil && !tabs.isEmpty }
    var isExpanded: Bool { isShown && state.isExpanded }
    var selectedTabID: String? { state.resolvedSelection(available: tabs.map(\.id)) }
    var mounts: LeoAgentPaneMounts { LeoAgentPaneMounts(tabs: tabs, state: state, agent: agent) }

    func setAgent(_ next: LeoAgentPaneAgent?) {
        guard next != agent else { return }
        agent = next
        openSlots()
    }

    func tapTab(_ id: String) { apply(state.tappingTab(id, available: tabs.map(\.id))) }
    func toggle() { apply(state.toggled(available: tabs.map(\.id))) }

    func setHeight(_ proposed: CGFloat, columnHeight: CGFloat) {
        apply(state.settingHeight(proposed, columnHeight: columnHeight))
    }

    // MARK: Private

    private func apply(_ next: LeoAgentPaneState) {
        guard next != state else { return }
        state = next
        store.save(next)
        openSlots()
    }

    private func refreshTabs(showsTerminal: Bool? = nil) {
        let next = LeoAgentPaneTabs.make(
            from: surfaces?.manager?.plugins ?? [], showsTerminal: showsTerminal ?? settings.showsTerminalTab)
        guard next != tabs else { return }
        tabs = next
        openSlots()
    }

    /// Asks each plugin for the slots the pane is about to show, once each:
    /// a slot the plugin already holds is skipped.
    private func openSlots() {
        guard let manager = surfaces?.manager else { return }
        let mounts = mounts
        for key in mounts.pluginKeys {
            guard !manager.slots.slots(of: key.pluginID).contains(key.slot) else { continue }
            manager.open(key.slot, plugin: key.pluginID)
        }
    }
}
