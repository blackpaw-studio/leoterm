import LeoKit

/// The pane slots that are mounted for an agent: every tab's summary, and the
/// selected tab's body while the drawer is open. Mounted slots are on screen,
/// and a mounted host reports its visibility through the ref-counted reporter,
/// so a body that is not mounted is never visible: its `leo.after` and refresh
/// wait. Pure, so each state's slots are tested without a view.
struct LeoAgentPaneMounts: Equatable {
    let summaries: [LeoPluginSlotKey]
    let body: LeoPluginSlotKey?

    static let none = LeoAgentPaneMounts(summaries: [], body: nil)

    init(summaries: [LeoPluginSlotKey], body: LeoPluginSlotKey?) {
        self.summaries = summaries
        self.body = body
    }

    init(tabs: [LeoAgentPaneTab], state: LeoAgentPaneState, agent: LeoPluginAgentRef?) {
        guard let agent, !tabs.isEmpty else {
            self = .none
            return
        }
        func key(_ tab: LeoAgentPaneTab, _ part: LeoPluginPanePart) -> LeoPluginSlotKey {
            LeoPluginSlotKey(pluginID: tab.id, slot: .pane(id: tab.paneID, part: part, agent: agent))
        }
        let selected = state.resolvedSelection(available: tabs.map(\.id))
        summaries = tabs.map { key($0, .summary) }
        body = state.isExpanded ? tabs.first { $0.id == selected }.map { key($0, .body) } : nil
    }
}
