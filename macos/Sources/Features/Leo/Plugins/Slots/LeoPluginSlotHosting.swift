import Combine
import LeoKit

/// What the slots (sidebar sections, palette commands) need from the plugin
/// manager: opening, Retry and Hide, never drawing or visibility (see
/// `LeoPluginSlotSurface`). The manager conforms; tests pass a fake.
@MainActor protocol LeoPluginSlotHosting: AnyObject {
    var plugins: [LeoPluginInfo] { get }
    var slots: LeoPluginSlotStore { get }
    @discardableResult func open(_ slot: LeoPluginSlotID, plugin id: String) -> Bool
    func retry(_ key: LeoPluginSlotKey)
    func perform(_ action: LeoPluginAction, plugin id: String, slot: LeoPluginSlotID?, gesture: LeoPluginGesture?)
    func setSection(_ id: String, section: String, hidden: Bool) throws
    /// A command's handler finished and its palette slot never rendered.
    var commandFinishedWithoutRender: AnyPublisher<LeoPluginSlotKey, Never> { get }
}

extension LeoPluginManager: LeoPluginSlotHosting {}
