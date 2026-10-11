import ComposableArchitecture
import Foundation
import Security

/// Per-daemon credentials in the Keychain.
@DependencyClient
public struct SecretsClient: Sendable {
    public var load: @Sendable (_ daemonID: String) throws -> DaemonSecrets?
    public var save: @Sendable (_ secrets: DaemonSecrets, _ daemonID: String) throws -> Void
    public var delete: @Sendable (_ daemonID: String) throws -> Void
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}

extension SecretsClient: DependencyKey {
    public static let testValue = SecretsClient()

    /// Generic passwords, one per daemon, readable after first unlock on
    /// this device only (so a future notification extension can read them
    /// while the phone is locked, and they never sync or back up).
    public static var liveValue: SecretsClient {
        let service = "studio.blackpaw.leo.ios.daemon"
        @Sendable func query(_ daemonID: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: daemonID]
        }
        return SecretsClient(
            load: { daemonID in
                var lookup = query(daemonID)
                lookup[kSecReturnData as String] = true
                lookup[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: AnyObject?
                let status = SecItemCopyMatching(lookup as CFDictionary, &result)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
                return try JSONDecoder().decode(DaemonSecrets.self, from: data)
            },
            save: { secrets, daemonID in
                let data = try JSONEncoder().encode(secrets)
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                var status = SecItemUpdate(query(daemonID) as CFDictionary, attributes as CFDictionary)
                if status == errSecItemNotFound {
                    status = SecItemAdd(query(daemonID).merging(attributes) { $1 } as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw KeychainError(status: status) }
            },
            delete: { daemonID in
                let status = SecItemDelete(query(daemonID) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            }
        )
    }
}

extension DependencyValues {
    public var secrets: SecretsClient {
        get { self[SecretsClient.self] }
        set { self[SecretsClient.self] = newValue }
    }
}
