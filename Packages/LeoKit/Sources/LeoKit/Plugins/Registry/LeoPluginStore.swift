import Foundation

/// Where plugin files live: `~/Library/Application Support/Leo/Plugins/`, and
/// `Leo-Debug/Plugins` for debug builds so a debug app never touches the
/// installed app's plugins (Q15).
public enum LeoPluginRoot {
    public static func url(applicationSupport: URL, isDebugBuild: Bool) -> URL {
        applicationSupport
            .appendingPathComponent(isDebugBuild ? "Leo-Debug" : "Leo", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }
}

/// The registry on disk: `<root>/registry.json`, written atomically after
/// every change. Also the live `LeoPluginIDClaimLookup` for the installer.
public final class LeoPluginStore: @unchecked Sendable, LeoPluginIDClaimLookup {
    public static let fileName = "registry.json"

    public let root: URL
    /// Why the last load discarded a file, if it did.
    public private(set) var loadIssue: String?

    private let lock = NSLock()
    private var current = LeoPluginRegistry()

    public init(root: URL) {
        self.root = root
        load()
    }

    public var registry: LeoPluginRegistry { lock.withLock { current } }

    /// Applies `change` and writes the result. If the write fails the in-memory
    /// registry is left as it was and the error is thrown.
    @discardableResult
    public func update<T>(_ change: (inout LeoPluginRegistry) throws -> T) throws -> T {
        try lock.withLock {
            var next = current
            let value = try change(&next)
            try write(next)
            current = next
            return value
        }
    }

    public func claim(forID id: String) -> LeoPluginIDClaim? { registry.claim(forID: id) }

    // MARK: Private

    private var file: URL { root.appendingPathComponent(Self.fileName) }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            current = try JSONDecoder().decode(LeoPluginRegistry.self, from: data)
        } catch {
            // Don't overwrite what the user can't recover: move it aside and start empty.
            let aside = root.appendingPathComponent("registry.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            loadIssue = "The plugin registry was unreadable and was moved to \(aside.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func write(_ registry: LeoPluginRegistry) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: file, options: .atomic)
    }
}
