import LeoKit

/// The agent pane's tabs, from the plugins Leo knows. Pure, so ordering,
/// hiding and the crashed-plugin warning are tested without a view.
///
/// A plugin contributes at most one pane in v1, so the plugin's id is the
/// tab's id (and what `LeoAgentPaneState` remembers as the selection).
struct LeoAgentPaneTab: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A pane a plugin renders, named by the plugin's own pane id.
        case plugin(paneID: String)
        /// The built-in shell tab (the drawer Terminal).
        case terminal
    }

    /// The built-in Terminal tab's id, reserved: a plugin with this id gets no tab.
    static let terminalID = "leo.terminal"

    static let terminal = LeoAgentPaneTab(
        id: terminalID, kind: .terminal, title: "Terminal", sfSymbol: "terminal", hasWarning: false)

    let id: String
    let kind: Kind
    let title: String
    let sfSymbol: String?
    /// The plugin crashed, was crash-disabled, or can't run: the tab stays,
    /// so the user can see why, with a warning glyph.
    let hasWarning: Bool

    /// The plugin's pane id, nil for a built-in tab.
    var paneID: String? {
        if case .plugin(let paneID) = kind { return paneID }
        return nil
    }

    static let warningSymbol = "exclamationmark.triangle.fill"
    static let fallbackSymbol = "info.circle"

    /// The SF Symbol the tab draws: a warning glyph for a plugin that isn't
    /// running, else the pane's own symbol, else ⓘ when the pane named none or
    /// the name isn't a symbol on this system.
    func iconName(isResolvable: (String) -> Bool) -> String {
        if hasWarning { return Self.warningSymbol }
        guard let sfSymbol, isResolvable(sfSymbol) else { return Self.fallbackSymbol }
        return sfSymbol
    }
}

enum LeoAgentPaneTabs {
    /// The built-in Terminal tab first (when `showsTerminal`), then
    /// first-party (bundled) plugins, then the rest, each group in the order
    /// given. Leaves out plugins the user turned off, panes the user hid, and
    /// plugins with no manifest or no pane. A plugin that claims the Terminal
    /// tab's id is dropped: the id is the tab's selection key.
    static func make(from plugins: [LeoPluginInfo], showsTerminal: Bool = true) -> [LeoAgentPaneTab] {
        let tabs = plugins.filter { $0.id != LeoAgentPaneTab.terminalID }.compactMap(tab(for:))
        let firstParty = Set(plugins.filter { $0.source == .bundled }.map(\.id))
        let ordered = tabs.filter { firstParty.contains($0.id) } + tabs.filter { !firstParty.contains($0.id) }
        return (showsTerminal ? [LeoAgentPaneTab.terminal] : []) + ordered
    }

    private static func tab(for plugin: LeoPluginInfo) -> LeoAgentPaneTab? {
        guard plugin.isEnabled, let pane = plugin.manifest?.contributes.panes.first,
              !plugin.hiddenPanes.contains(pane.id)
        else { return nil }
        return LeoAgentPaneTab(
            id: plugin.id, kind: .plugin(paneID: pane.id), title: pane.title, sfSymbol: pane.sfSymbol, hasWarning: plugin.state != .running)
    }
}
