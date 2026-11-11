import Foundation

/// A plugin as the user knows it: the name goes on every confirmation sheet.
public struct LeoPluginIdentity: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Carries out an action the gate already authorized. Implemented by
/// `LeoPluginActionExecutor` (3.7); the router and manager only know this.
@MainActor public protocol LeoPluginActionRunning: AnyObject {
    /// `callback` is not here: the manager delivers those itself.
    /// - pushView: onto `slot`'s stack; openURL (https) and copy: straight away.
    func perform(_ action: LeoPluginAction, plugin: LeoPluginIdentity, slot: LeoPluginSlotID?)
    /// `sendToAgent` or `spawnAgent`: open the confirmation sheet; call the
    /// daemon only after the person confirms.
    func confirm(_ action: LeoPluginAction, plugin: LeoPluginIdentity)
}
