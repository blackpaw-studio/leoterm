import Foundation

/// The agents across paired machines, as a non-secret JSON file the app
/// keeps current and an extension reads (a Control's agent picker can't
/// reach the Keychain). It holds names only: no tokens, no URLs.
public struct LeoAgentDirectorySnapshotStore: Sendable {
    public static let filename = "agent-directory.json"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The snapshot in an app group's shared container; nil when the group isn't available.
    public static func appGroup(identifier: String) -> Self? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            .map { Self(url: $0.appending(path: filename)) }
    }

    /// The saved agents; empty when there is no file or it can't be read.
    public func read() -> [LeoAgentTarget] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LeoAgentTarget].self, from: data)) ?? []
    }

    /// Saves `targets`, unless they are what is already saved. An empty
    /// list is not saved: it means the app hasn't heard from a machine yet,
    /// not that every agent is gone.
    public func write(_ targets: [LeoAgentTarget]) throws {
        guard !targets.isEmpty, targets != read() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(targets).write(to: url, options: .atomic)
    }
}
