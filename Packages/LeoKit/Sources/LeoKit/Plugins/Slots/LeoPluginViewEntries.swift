import Foundation

/// One plugin view a person can open on an agent, as menus list it.
public struct LeoPluginViewEntry: Equatable, Sendable, Identifiable {
    public let pluginID: String
    public let pluginName: String
    public let viewID: String
    public let title: String
    public let sfSymbol: String

    public var id: String { "\(pluginID)/\(viewID)" }
}

/// The views the toolbar menu and the row context menu list next to Browser
/// and Editor: those of every plugin that is on and usable.
public enum LeoPluginViewEntries {
    public static func make(from plugins: [LeoPluginInfo]) -> [LeoPluginViewEntry] {
        plugins
            .filter(isListed)
            .sorted { $0.id < $1.id }
            .flatMap { plugin in
                (plugin.manifest?.contributes.views ?? []).map {
                    LeoPluginViewEntry(pluginID: plugin.id, pluginName: plugin.name, viewID: $0.id, title: $0.title, sfSymbol: $0.sfSymbol)
                }
            }
    }

    /// A restarting plugin keeps its entries (its pane shows the error until it is back).
    private static func isListed(_ plugin: LeoPluginInfo) -> Bool {
        guard plugin.isEnabled, plugin.manifest != nil else { return false }
        switch plugin.state {
        case .running, .restarting: return true
        case .stoppedByUser, .needsApproval, .disabled, .refused: return false
        }
    }
}
