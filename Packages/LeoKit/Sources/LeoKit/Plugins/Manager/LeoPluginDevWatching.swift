import Foundation

/// What to watch for one dev plugin.
public struct LeoPluginDevTarget: Equatable, Sendable {
    public let id: String
    public let urls: [URL]

    public init(id: String, urls: [URL]) {
        self.id = id
        self.urls = urls
    }
}

/// Reloads a dev plugin when its files change. The manager hands it the
/// current set of dev plugins after every reload.
@MainActor public protocol LeoPluginDevWatching: AnyObject {
    func sync(_ targets: [LeoPluginDevTarget])
    func stopAll()
}
