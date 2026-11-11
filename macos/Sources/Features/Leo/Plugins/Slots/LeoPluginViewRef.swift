import Combine
import Foundation
import LeoKit

/// One plugin view opened on one agent: what a row's pane keeps while the
/// view is open. The slot (and so the event the plugin gets) is derived from
/// it, so plugin code never builds one.
struct LeoPluginViewRef: Hashable {
    let pluginID: String
    let pluginName: String
    let viewID: String
    let title: String
    let sfSymbol: String
    let agent: LeoPluginAgentRef

    init(pluginID: String, pluginName: String, viewID: String, title: String, sfSymbol: String, agent: LeoPluginAgentRef) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.viewID = viewID
        self.title = title
        self.sfSymbol = sfSymbol
        self.agent = agent
    }

    init(entry: LeoPluginViewEntry, agent: LeoPluginAgentRef) {
        self.init(
            pluginID: entry.pluginID, pluginName: entry.pluginName, viewID: entry.viewID, title: entry.title,
            sfSymbol: entry.sfSymbol, agent: agent)
    }

    var slot: LeoPluginSlotID { .view(viewID: viewID, agent: agent) }
    var slotKey: LeoPluginSlotKey { LeoPluginSlotKey(pluginID: pluginID, slot: slot) }
}

/// What a row's plugin view asks of the plugin system. The pane depends on
/// this, not on the manager, so it is driven by a fake in tests.
@MainActor protocol LeoPluginPaneHosting: AnyObject {
    /// Fires (before the change lands) whenever any slot or plugin changes.
    var changes: AnyPublisher<Void, Never> { get }
    func slotContent(for ref: LeoPluginViewRef) -> LeoPluginSlotContent
    /// The person opened the view: the plugin gets `viewOpened`.
    func open(_ ref: LeoPluginViewRef)
    func retry(_ ref: LeoPluginViewRef)
    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?, in ref: LeoPluginViewRef)
    /// Back out of a pushed view.
    func pop(_ ref: LeoPluginViewRef)
    /// Whether the view is on screen (the plugin's `leo.after` timers wait for it).
    func setVisible(_ ref: LeoPluginViewRef, _ visible: Bool)
}
