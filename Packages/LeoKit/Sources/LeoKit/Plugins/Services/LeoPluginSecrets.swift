import Foundation

/// A generic-password store. The Mac app implements it over the Keychain;
/// tests use a dictionary.
public protocol LeoPluginKeychain: Sendable {
    func get(service: String, account: String) throws -> String?
    /// Adds or replaces the item.
    func set(service: String, account: String, value: String) throws
    /// Deleting a missing item is not an error.
    func delete(service: String, account: String) throws
    /// Deletes every item whose service is *exactly* `service`.
    func deleteAll(service: String) throws
}

public enum LeoPluginKeychainError: Error, Equatable, Sendable {
    case status(Int32)
    case unreadable
}

public enum LeoPluginSecretsError: Error, Equatable, LocalizedError, Sendable {
    case invalidPluginID(String)
    case invalidKey(String)
    case valueTooLarge(limit: Int)
    case permissionDenied(String)
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPluginID(let id): "'\(id)' is not a valid plugin id"
        case .invalidKey(let key):
            "secret key '\(key.prefix(64))' is not valid: use 1–64 characters from A-Z a-z 0-9 . _ -"
        case .valueTooLarge(let limit): "secret value is larger than \(limit / 1024) KB"
        case .permissionDenied(let reason): reason
        case .keychain(let reason): "keychain error: \(reason)"
        }
    }
}

/// `leo.secrets` for one plugin: Keychain items with service `leo.plugin.<id>`
/// and account `<key>`. Service and account are separate attributes, so one
/// plugin's id and keys can never alias another's, and uninstall matches the
/// service exactly (`leo.plugin.a.b` is not swept up by removing `a`).
public struct LeoPluginSecrets: Sendable {
    public static let maxValueBytes = 16 * 1024
    static let maxKeyBytes = 64
    public static let servicePrefix = "leo.plugin."

    private let engine: LeoPluginPermissionEngine
    private let keychain: any LeoPluginKeychain
    public let service: String

    public init(pluginID: String, engine: LeoPluginPermissionEngine, keychain: any LeoPluginKeychain) throws {
        guard LeoPluginManifestValidator.isReverseDNS(pluginID) else { throw LeoPluginSecretsError.invalidPluginID(pluginID) }
        service = Self.servicePrefix + pluginID
        self.engine = engine
        self.keychain = keychain
    }

    public func get(key: String) throws -> String? {
        try authorize(key: key)
        return try guarded { try keychain.get(service: service, account: key) }
    }

    public func set(key: String, value: String) throws {
        try authorize(key: key)
        guard value.utf8.count <= Self.maxValueBytes else { throw LeoPluginSecretsError.valueTooLarge(limit: Self.maxValueBytes) }
        try guarded { try keychain.set(service: service, account: key, value: value) }
    }

    public func delete(key: String) throws {
        try authorize(key: key)
        try guarded { try keychain.delete(service: service, account: key) }
    }

    /// Uninstall cleanup. Not gated on the manifest: it is the app's own housekeeping.
    public func removeAll() throws {
        try guarded { try keychain.deleteAll(service: service) }
    }

    private func authorize(key: String) throws {
        if case .denied(let reason) = engine.checkSecrets() { throw LeoPluginSecretsError.permissionDenied(reason) }
        guard Self.isValidKey(key) else { throw LeoPluginSecretsError.invalidKey(key) }
    }

    static func isValidKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return (1...maxKeyBytes).contains(bytes.count)
            && bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    private func guarded<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw LeoPluginSecretsError.keychain(String(describing: error))
        }
    }
}
