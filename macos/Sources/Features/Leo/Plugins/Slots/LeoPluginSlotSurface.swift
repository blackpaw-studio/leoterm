import Combine
import LeoKit

/// What every slot surface (a row's pane, the palette page, a sidebar section)
/// asks of the plugin system: what its slot shows now, and where its actions,
/// Retry, Back and visibility go. `LeoPluginSurfaces` is the one conformer in
/// the app; nothing else reaches the manager, so slot visibility is counted in
/// one place.
@MainActor protocol LeoPluginSlotSurface: AnyObject {
    /// Fires (before the change lands) whenever any slot or plugin changes.
    var changes: AnyPublisher<Void, Never> { get }
    func content(for key: LeoPluginSlotKey) -> LeoPluginSlotContent
    /// Re-sends the event that produced an error slot.
    func retry(_ key: LeoPluginSlotKey)
    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?, in key: LeoPluginSlotKey)
    /// Back out of a pushed view.
    func pop(_ key: LeoPluginSlotKey)
    /// Whether a surface of the slot is on screen (the plugin's `leo.after` timers wait for any).
    func setVisible(_ key: LeoPluginSlotKey, _ visible: Bool)
}
