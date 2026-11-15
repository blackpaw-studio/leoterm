import Foundation

/// Which of each plugin's slots are on screen, as a count per slot, so a
/// plugin counts as visible while any of its slots is (its `leo.after` timers
/// wait for that). Closing one slot, say the palette, must not hide a plugin
/// whose pane is still open.
public struct LeoPluginSlotVisibility: Sendable {
    private var counts: [LeoPluginSlotKey: Int] = [:]

    public init() {}

    public func isVisible(plugin id: String) -> Bool { counts.keys.contains { $0.pluginID == id } }

    /// Whether one of the plugin's pane slots (summary or body) is on screen.
    /// The app compares this around each `set` and tells the manager when it flips.
    public func isPaneVisible(plugin id: String) -> Bool {
        counts.keys.contains { key in
            guard key.pluginID == id, case .pane = key.slot else { return false }
            return true
        }
    }

    /// Records one surface of `key` appearing or disappearing. Returns the
    /// plugin's new visibility when this changed it, nil when it didn't.
    public mutating func set(_ key: LeoPluginSlotKey, visible: Bool) -> Bool? {
        let before = isVisible(plugin: key.pluginID)
        let count = max(0, (counts[key] ?? 0) + (visible ? 1 : -1))
        counts[key] = count == 0 ? nil : count
        let after = isVisible(plugin: key.pluginID)
        return before == after ? nil : after
    }
}
