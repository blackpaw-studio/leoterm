import Foundation
import Security

/// What the app shares with its Notification Service Extension, in the
/// Keychain under an access group both hold: the push key, and which
/// daemons are paired (so the extension can ignore pushes from forgotten
/// ones). Readable after first unlock (pushes arrive while the phone is
/// locked), never synced or backed up.
public struct LeoPushSharedStore: Sendable {
    /// The iOS app group, used as the shared keychain access group.
    public static let iOSAccessGroup = "group.studio.blackpaw.leo.ios"

    public let accessGroup: String
    let service = "studio.blackpaw.leo.ios.push"
    static let keyAccount = "push-key"
    static let daemonsAccount = "paired-daemon-ids"

    public init(accessGroup: String = Self.iOSAccessGroup) {
        self.accessGroup = accessGroup
    }

    public func loadKey() throws -> LeoPushKey? {
        guard let data = try load(Self.keyAccount) else { return nil }
        guard let key = LeoPushKey(data: data) else { throw LeoPushKeyStoreError(status: errSecDecode) }
        return key
    }

    /// The stored key, generating and storing one the first time. Should
    /// two callers race, the one that lost reads the winner's.
    public func loadOrCreateKey() throws -> LeoPushKey {
        if let key = try loadKey() { return key }
        let key = LeoPushKey.generate()
        var attributes = query(Self.keyAccount)
        attributes[kSecValueData as String] = key.data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let stored = try loadKey() { return stored }
        guard status == errSecSuccess else { throw LeoPushKeyStoreError(status: status) }
        return key
    }

    /// Empty until the app first shares them.
    public func loadPairedDaemonIDs() throws -> Set<String> {
        guard let data = try load(Self.daemonsAccount) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    public func savePairedDaemonIDs(_ ids: Set<String>) throws {
        let data = try JSONEncoder().encode(ids.sorted())
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(Self.daemonsAccount) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(Self.daemonsAccount).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LeoPushKeyStoreError(status: status) }
    }

    private func load(_ account: String) throws -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LeoPushKeyStoreError(status: status) }
        return data
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public struct LeoPushKeyStoreError: Error, Equatable, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}
