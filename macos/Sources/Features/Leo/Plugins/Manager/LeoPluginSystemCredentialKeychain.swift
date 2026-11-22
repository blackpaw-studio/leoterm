import Foundation
import LeoKit
import Security

/// Reads a CLI's own Keychain item (Claude Code's `Claude Code-credentials…`)
/// for the `credentials` permission. Read-only: no add, update or delete.
///
/// No-UI reads: the items belong to another app (created by `/usr/bin/security`,
/// legacy ACL + `apple-tool:` partition), so a read from Leo shows the
/// "Leo wants to access…" dialog until the user picks Always Allow. Of the
/// SecItem options, only the deprecated `SecKeychainSetUserInteractionAllowed(false)`
/// suppresses that dialog: it fails fast with `errSecAuthFailed` (-25293).
/// `kSecUseAuthenticationUIFail` and `LAContext.interactionNotAllowed` both
/// still block on the dialog (spike, 2026-11-21). The flag is process-wide, so
/// every read here holds one lock across set → read → restore.
///
/// Call off the main thread: a read with `allowUI` blocks while the dialog is up.
struct LeoPluginSystemCredentialKeychain: LeoPluginCredentialKeychain {
    private static let interactionLock = NSLock()

    func password(service: String, account: String, allowUI: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = Self.interactionLock.withLock {
            guard !allowUI else { return SecItemCopyMatching(query as CFDictionary, &result) }
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw LeoPluginCredentialKeychainError.notFound }
            return data
        case errSecItemNotFound:
            throw LeoPluginCredentialKeychainError.notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            // No-UI read that would need the dialog, or the user said Deny.
            throw LeoPluginCredentialKeychainError.needsAuthorization
        default:
            throw LeoPluginCredentialKeychainError.notFound
        }
    }
}
