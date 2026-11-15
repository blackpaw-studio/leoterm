import Foundation

/// What a plugin surface (a pane, a section) shows for its slot right now.
/// The routing between the slot store's states and the renderers, kept pure.
public enum LeoPluginSlotContent: Equatable, Sendable {
    public static let unavailableNotice = "This plugin is no longer available."

    case loading
    /// The slot's tree, or the top of its pushed stack (`isPushed`, so the surface offers Back).
    case nodes([LeoPluginNode], isPushed: Bool)
    /// A failure Retry can re-send.
    case error(String)
    /// Nothing to retry: the plugin is off, crash-disabled or gone.
    case notice(String)

    public static func resolve(state: LeoPluginSlotState, pushed: [LeoPluginNode], pluginAvailable: Bool) -> Self {
        guard pluginAvailable else { return .notice(unavailableNotice) }
        switch state {
        case .loading: return .loading
        case .error(let message): return .error(message)
        case .disabled(let reason): return .notice(reason)
        case .tree(let root):
            if let top = pushed.last { return .nodes([top], isPushed: true) }
            return .nodes(root.nodes, isPushed: false)
        }
    }
}
