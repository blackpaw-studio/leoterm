import LeoKit

/// The agent pane's tabs, from the plugins Leo knows. Pure, so ordering,
/// hiding and the crashed-plugin warning are tested without a view.
///
/// A plugin contributes at most one pane in v1, so the plugin's id is the
/// tab's id (and what `LeoAgentPaneState` remembers as the selection).
struct LeoAgentPaneTab: Equatable, Identifiable {
    let id: String
    let paneID: String
    let title: String
    let sfSymbol: String?
    /// The plugin crashed, was crash-disabled, or can't run: the tab stays,
    /// so the user can see why, with a warning glyph.
    let hasWarning: Bool
}

enum LeoAgentPaneTabs {
    /// First-party (bundled) plugins first, then the rest, each group in the
    /// order given. Leaves out plugins the user turned off, panes the user
    /// hid, and plugins with no manifest or no pane.
    static func make(from plugins: [LeoPluginInfo]) -> [LeoAgentPaneTab] {
        let tabs = plugins.compactMap(tab(for:))
        let firstParty = Set(plugins.filter { $0.source == .bundled }.map(\.id))
        return tabs.filter { firstParty.contains($0.id) } + tabs.filter { !firstParty.contains($0.id) }
    }

    private static func tab(for plugin: LeoPluginInfo) -> LeoAgentPaneTab? {
        guard plugin.isEnabled, let pane = plugin.manifest?.contributes.panes.first,
              !plugin.hiddenPanes.contains(pane.id)
        else { return nil }
        return LeoAgentPaneTab(
            id: plugin.id, paneID: pane.id, title: pane.title, sfSymbol: pane.sfSymbol, hasWarning: plugin.state != .running)
    }
}
