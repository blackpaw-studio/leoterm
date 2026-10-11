import Foundation
import Security

/// The push key in the Keychain, in an access group the app shares with its
/// Notification Service Extension. Readable after first unlock (pushes
/// arrive while the phone is locked), never synced or backed up.
public struct LeoPushKeyStore: Sendable {
    /// The iOS app group, used as the shared keychain access group.
    public static let iOSAccessGroup = "group.studio.blackpaw.leo.ios"

    public let accessGroup: String
    let service = "studio.blackpaw.leo.ios.push"
    let account = "push-key"

    public init(accessGroup: String = Self.iOSAccessGroup) {
        self.accessGroup = accessGroup
    }

    public func load() throws -> LeoPushKey? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LeoPushKeyStoreError(status: status) }
        guard let key = LeoPushKey(data: data) else { throw LeoPushKeyStoreError(status: errSecDecode) }
        return key
    }

    /// The stored key, generating and storing one the first time. Should
    /// two callers race, the one that lost reads the winner's.
    public func loadOrCreate() throws -> LeoPushKey {
        if let key = try load() { return key }
        let key = LeoPushKey.generate()
        var attributes = query
        attributes[kSecValueData as String] = key.data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let stored = try load() { return stored }
        guard status == errSecSuccess else { throw LeoPushKeyStoreError(status: status) }
        return key
    }

    private var query: [String: Any] {
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
