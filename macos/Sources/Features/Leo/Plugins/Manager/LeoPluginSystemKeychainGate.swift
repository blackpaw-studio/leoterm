import Foundation
import LeoKit
import Security

extension LeoPluginKeychainGate {
    /// The gate every plugin-system Keychain call shares (`leo.secrets` and
    /// account credentials). This is the only code in the app that touches
    /// `SecKeychainSetUserInteractionAllowed`. The API is deprecated, but it is
    /// the only no-UI option that suppresses the legacy-ACL dialog for another
    /// app's item (spike, 2026-11-21). The flag is process-wide, hence one gate.
    static let system = LeoPluginKeychainGate(
        interaction: Interaction(
            isAllowed: {
                var allowed: DarwinBoolean = true
                let status = SecKeychainGetUserInteractionAllowed(&allowed)
                guard status == errSecSuccess else { throw LeoPluginKeychainGateError.interactionStatus(status) }
                return allowed.boolValue
            },
            setAllowed: { allowed in
                let status = SecKeychainSetUserInteractionAllowed(allowed)
                guard status == errSecSuccess else { throw LeoPluginKeychainGateError.interactionStatus(status) }
            }),
        restoreFailed: { error in
            LeoLog.logger(category: "leo.plugins").fault("Keychain interaction flag couldn't be restored: \(String(describing: error), privacy: .public)")
        })
}
