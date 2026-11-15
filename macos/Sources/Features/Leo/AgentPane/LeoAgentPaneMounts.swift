import LeoKit

/// The agent the pane shows: the reference plugins key their slots on, and
/// the identity the built-in Terminal launches its shell from.
struct LeoAgentPaneAgent: Equatable {
    let ref: LeoPluginAgentRef
    let identity: LeoAgentIdentity
}

/// One thing the pane mounts: a plugin's pane slot, or the built-in Terminal.
enum LeoAgentPaneMount: Equatable {
    case plugin(LeoPluginSlotKey)
    case terminal(LeoAgentIdentity)

    var pluginKey: LeoPluginSlotKey? {
        if case .plugin(let key) = self { return key }
        return nil
    }
}

/// The pane slots that are mounted for an agent: every tab's summary, and the
/// selected tab's body while the drawer is open. Mounted plugin slots are on
/// screen, and a mounted host reports its visibility through the ref-counted
/// reporter, so a body that is not mounted is never visible: its `leo.after`
/// and refresh wait. The Terminal has no plugin slot: it is mounted by
/// identity and starts its shell when its body is mounted. Pure, so each
/// state's mounts are tested without a view.
struct LeoAgentPaneMounts: Equatable {
    let summaries: [LeoAgentPaneMount]
    let body: LeoAgentPaneMount?

    static let none = LeoAgentPaneMounts(summaries: [], body: nil)

    init(summaries: [LeoAgentPaneMount], body: LeoAgentPaneMount?) {
        self.summaries = summaries
        self.body = body
    }

    init(tabs: [LeoAgentPaneTab], state: LeoAgentPaneState, agent: LeoAgentPaneAgent?) {
        guard let agent, !tabs.isEmpty else {
            self = .none
            return
        }
        func mount(_ tab: LeoAgentPaneTab, _ part: LeoPluginPanePart) -> LeoAgentPaneMount {
            switch tab.kind {
            case .terminal:
                return .terminal(agent.identity)
            case .plugin(let paneID):
                return .plugin(LeoPluginSlotKey(pluginID: tab.id, slot: .pane(id: paneID, part: part, agent: agent.ref)))
            }
        }
        let selected = state.resolvedSelection(available: tabs.map(\.id))
        summaries = tabs.map { mount($0, .summary) }
        body = state.isExpanded ? tabs.first { $0.id == selected }.map { mount($0, .body) } : nil
    }

    /// The plugin slots on screen, in order: what the visibility reporters
    /// and the model's slot opening see. The Terminal has none.
    var pluginKeys: [LeoPluginSlotKey] {
        (summaries + (body.map { [$0] } ?? [])).compactMap(\.pluginKey)
    }
}
