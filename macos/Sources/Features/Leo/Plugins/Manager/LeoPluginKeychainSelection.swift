import Foundation
import LeoKit

/// Chooses the Keychain behind `leo.secrets`. Release builds always get the
/// system Keychain. A Debug build also honours `LEO_PLUGIN_KEYCHAIN_FILE`, so
/// an isolated debug app (its own HOME can't see the real login keychain) can
/// run a plugin against a token kept in a file. The seam is compiled out of
/// Release: the variable isn't read and the file store doesn't exist there.
enum LeoPluginKeychainSelection {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> any LeoPluginKeychain {
        #if DEBUG
        if let path = environment["LEO_PLUGIN_KEYCHAIN_FILE"], !path.isEmpty {
            return LeoPluginFileKeychain(url: URL(fileURLWithPath: path))
        }
        #endif
        return LeoPluginSystemKeychain()
    }
}

#if DEBUG
/// DEBUG only. Items live in one JSON file (mode 0600), keyed `service\0account`.
/// Service matching is exact, like the system Keychain's.
final class LeoPluginFileKeychain: LeoPluginKeychain, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func get(service: String, account: String) throws -> String? {
        try locked { $0[Self.key(service, account)] }
    }

    func set(service: String, account: String, value: String) throws {
        try mutate { $0.merging([Self.key(service, account): value]) { $1 } }
    }

    func delete(service: String, account: String) throws {
        try mutate { $0.filter { $0.key != Self.key(service, account) } }
    }

    func deleteAll(service: String) throws {
        try mutate { $0.filter { !$0.key.hasPrefix(service + "\0") } }
    }

    private static func key(_ service: String, _ account: String) -> String { service + "\0" + account }

    private func locked<R>(_ body: ([String: String]) throws -> R) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(try load())
    }

    private func mutate(_ change: ([String: String]) -> [String: String]) throws {
        try locked { try save(change($0)) }
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let items = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) else {
            throw LeoPluginKeychainError.unreadable
        }
        return items
    }

    private func save(_ items: [String: String]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
