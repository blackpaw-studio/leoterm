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
/// every read goes through the shared `LeoPluginKeychainGate`.
///
/// Call off the main thread: a read with `allowUI` blocks while the dialog is up.
struct LeoPluginSystemCredentialKeychain: LeoPluginCredentialKeychain {
    var gate: LeoPluginKeychainGate = .system

    func password(service: String, account: String, allowUI: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status: OSStatus
        do {
            status = try gate.run(allowUI: allowUI) { SecItemCopyMatching(query as CFDictionary, &result) }
        } catch {
            // The flag couldn't be turned off, so a read now might show UI: don't read.
            throw LeoPluginCredentialKeychainError.needsAuthorization
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
