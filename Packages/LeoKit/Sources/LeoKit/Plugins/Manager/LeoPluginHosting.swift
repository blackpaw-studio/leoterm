import Foundation

/// How a plugin's helper process ended.
public enum LeoPluginHostTermination: Equatable, Sendable {
    /// Counts against the supervisor's crash budget. The reason is user-visible.
    case crashed(reason: String)
    /// `stop()` was called; not a crash.
    case stopped
}

/// One running helper process, as the manager sees it. The Mac app adapts its
/// `LeoPluginHostConnection`; tests use a fake. One value is one process: after
/// `onTermination` fires it is spent.
///
/// All callbacks arrive on the main queue, in order, and only the manager
/// sets them (before `start`).
public protocol LeoPluginHosting: AnyObject, Sendable {
    var onRequest: (@Sendable (LeoPluginHostRequest) -> Void)? { get set }
    var onTermination: (@Sendable (LeoPluginHostTermination) -> Void)? { get set }
    /// The helper finished one command (its `done` frame), in delivery order:
    /// first the bundle load, then one per delivered event. Async handlers
    /// have only run to their first await by then.
    var onHandlerDone: (@Sendable () -> Void)? { get set }
    /// Spawns the helper and hands it the plugin bundle's text.
    func start(source: String) throws
    func deliver(_ event: LeoPluginEvent) throws
    /// Kills the helper without it counting as a crash.
    func stop()
}

public protocol LeoPluginHostMaking: Sendable {
    func makeHost() -> any LeoPluginHosting
}

/// The agents Leo currently knows, across machines (the sidebar feeds).
@MainActor public protocol LeoPluginAgentSource: AnyObject {
    func currentAgents() -> [(LeoHostID, LeoAgent)]
    /// What is known about one agent's usage, or nil for an agent Leo doesn't know.
    func usage(for agent: LeoPluginAgentRef) -> LeoPluginUsageReading?
    /// This Mac's home directory, so a local workspace can be shown home-relative.
    var homeDirectory: String? { get }
}

extension LeoPluginAgentSource {
    public func usage(for agent: LeoPluginAgentRef) -> LeoPluginUsageReading? { nil }
    public var homeDirectory: String? { nil }
}

/// Moves a folder to the Trash (recoverable). Injected so tests don't touch the real one.
public protocol LeoPluginTrashing: Sendable {
    func moveToTrash(_ url: URL) throws
}
