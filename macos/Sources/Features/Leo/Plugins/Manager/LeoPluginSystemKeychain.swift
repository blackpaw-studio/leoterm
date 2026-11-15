import Foundation
import LeoKit
import Security

/// The Keychain behind `leo.secrets`: generic-password items, service
/// `leo.plugin.<id>`, account `<key>`. Service matching is exact, so removing
/// one plugin's items never touches another's.
struct LeoPluginSystemKeychain: LeoPluginKeychain {
    func get(service: String, account: String) throws -> String? {
        var query = identity(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw LeoPluginKeychainError.unreadable
        }
        return value
    }

    func set(service: String, account: String, value: String) throws {
        let query = identity(service: service, account: account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(identity(service: service, account: account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    func deleteAll(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        try check(status)
        for item in (result as? [[String: Any]]) ?? [] {
            // Re-check the service: delete only items that exactly match it.
            guard item[kSecAttrService as String] as? String == service,
                let account = item[kSecAttrAccount as String] as? String
            else { continue }
            try delete(service: service, account: account)
        }
    }

    private func identity(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw LeoPluginKeychainError.status(status) }
    }
}
