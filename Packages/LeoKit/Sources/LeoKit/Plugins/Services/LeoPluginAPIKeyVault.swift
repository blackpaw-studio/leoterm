import Foundation

public enum LeoPluginAPIKeyVaultError: Error, Equatable, Sendable {
    /// The key isn't a trimmed, non-empty, printable-ASCII string of at most 512 bytes.
    case invalidKey
    /// The plugin or grant id could alias another item's account.
    case invalidAccount
    /// The Keychain refused the write or delete. Never carries key material.
    case keychain
}

/// A key the user just pasted, on its way to the Keychain. Every rendering
/// (description, debug description, mirror) leaves the key out, so it can't
/// reach a log, an error or a crash report through string interpolation.
public struct LeoPluginAPIKeyEntry: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let key: String
    /// The account name the user gave (the provider's label by default).
    public let name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    public var description: String { "LeoPluginAPIKeyEntry(name: \(name), key: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["name": name, "key": "<redacted>"]) }
}

/// The Keychain items behind `api-key` grants: generic passwords with service
/// `Leo Plugin API Key` and account `<pluginID>/<grantID>`. A plugin id never
/// contains `/`, so one plugin's prefix can't match another's items.
///
/// Reads go through `reader`, which honours `allowUI` (background fetches never
/// show Keychain UI); writes and deletes go through `writer`.
public struct LeoPluginAPIKeyVault: Sendable {
    public static let service = "Leo Plugin API Key"
    public static let maxKeyBytes = 512

    private let reader: any LeoPluginCredentialKeychain
    private let writer: any LeoPluginKeychain

    public init(reader: any LeoPluginCredentialKeychain, writer: any LeoPluginKeychain) {
        self.reader = reader
        self.writer = writer
    }

    /// The key with surrounding whitespace trimmed, or nil unless what is left
    /// is non-empty printable ASCII with no whitespace, at most 512 bytes.
    public static func normalize(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= maxKeyBytes, key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return key
    }

    public static func account(pluginID: String, grantID: String) -> String? {
        guard LeoPluginManifestValidator.isReverseDNS(pluginID), isGrantID(grantID) else { return nil }
        return "\(pluginID)/\(grantID)"
    }

    /// Stores an already-normalized key for one grant.
    public func save(_ key: String, pluginID: String, grantID: String) throws(LeoPluginAPIKeyVaultError) {
        guard Self.normalize(key) == key else { throw .invalidKey }
        let account = try Self.requireAccount(pluginID: pluginID, grantID: grantID)
        do {
            try writer.set(service: Self.service, account: account, value: key)
        } catch {
            throw .keychain
        }
    }

    /// The fetch credential for one grant: `Authorization: Bearer <key>`, only for `host`.
    public func credential(
        pluginID: String, grantID: String, host: String, allowUI: Bool
    ) throws(LeoPluginCredentialError) -> LeoPluginFetchCredential {
        guard let account = Self.account(pluginID: pluginID, grantID: grantID) else { throw .invalid }
        let data: Data
        do {
            data = try reader.password(service: Self.service, account: account, allowUI: allowUI)
        } catch LeoPluginCredentialKeychainError.needsAuthorization {
            throw .needsAuthorization
        } catch {
            throw .notFound
        }
        guard let stored = String(data: data, encoding: .utf8), Self.normalize(stored) == stored else { throw .invalid }
        return LeoPluginFetchCredential(boundHost: host, headers: ["Authorization": "Bearer \(stored)"])
    }

    /// Deleting a missing item is not an error.
    public func delete(pluginID: String, grantID: String) throws(LeoPluginAPIKeyVaultError) {
        let account = try Self.requireAccount(pluginID: pluginID, grantID: grantID)
        do {
            try writer.delete(service: Self.service, account: account)
        } catch {
            throw .keychain
        }
    }

    /// Uninstall: every item of this plugin, including orphans no grant names.
    public func deleteAll(pluginID: String) throws(LeoPluginAPIKeyVaultError) {
        guard LeoPluginManifestValidator.isReverseDNS(pluginID) else { throw .invalidAccount }
        do {
            try writer.deleteAll(service: Self.service, accountPrefix: "\(pluginID)/")
        } catch {
            throw .keychain
        }
    }

    private static func requireAccount(pluginID: String, grantID: String) throws(LeoPluginAPIKeyVaultError) -> String {
        guard let account = account(pluginID: pluginID, grantID: grantID) else { throw .invalidAccount }
        return account
    }

    /// Grant ids are UUIDs; accept letters, digits and hyphens only.
    private static func isGrantID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return (1...64).contains(bytes.count)
            && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }
    }
}
