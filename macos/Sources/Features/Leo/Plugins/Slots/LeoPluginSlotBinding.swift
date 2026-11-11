import LeoKit

/// One slot as the app draws it: what it shows now, and where its actions go.
/// Shared by the sidebar section and the palette page.
@MainActor struct LeoPluginSlotBinding {
    /// An error slot's Retry. Slot-level failures have no plugin-supplied
    /// retry, so the renderer's Error node carries this marker and Leo
    /// re-sends the slot's own event instead of asking the plugin.
    static let retryAction = LeoPluginAction.callback(id: "leo.slot.retry", payload: .null)

    let host: any LeoPluginSlotHosting
    let key: LeoPluginSlotKey

    /// The components to draw: a pushed view over the slot's root, else the
    /// root, else Loading, the failure with Retry, or the unavailable notice.
    var nodes: [LeoPluginNode] {
        switch host.slots.state(key) {
        case .loading:
            return [.loading(.init(message: nil))]
        case .error(let message):
            return [.error(.init(message: message, retry: Self.retryAction))]
        case .disabled(let reason):
            return [.emptyState(.init(title: "Unavailable", message: reason, sfSymbol: "exclamationmark.triangle"))]
        case .tree(let root):
            return host.slots.pushed[key]?.last.map { [$0] } ?? root.nodes
        }
    }

    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?) {
        if action == Self.retryAction { return host.retry(key) }
        host.perform(action, plugin: key.pluginID, slot: key.slot, gesture: gesture)
    }

    /// Pops one pushed view. False at the root.
    @discardableResult func popPushed() -> Bool {
        guard host.slots.pushed[key]?.isEmpty == false else { return false }
        host.slots.pop(key)
        return true
    }
}
