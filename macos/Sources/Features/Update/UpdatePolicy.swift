import Sparkle

/// How Leo drives Sparkle: the `auto-update` config maps to the updater's
/// automatic-check and automatic-download settings, and debug builds can
/// check for updates but never install one (B-115).
enum UpdatePolicy {
    /// Sparkle's automatic-update settings for one `auto-update` value.
    struct Settings: Equatable {
        let checks: Bool
        let downloads: Bool
    }

    /// False in debug builds: they may find an update but must never
    /// download or install it over themselves.
    static let installsAllowed: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// The settings for `autoUpdate`, or nil when it is unset so Sparkle's
    /// own defaults (and its one-time permission prompt) apply. Automatic
    /// downloads stay off whenever installs aren't allowed.
    static func settings(for autoUpdate: Ghostty.Config.AutoUpdate?, installsAllowed: Bool) -> Settings? {
        guard let autoUpdate else { return nil }
        switch autoUpdate {
        case .off:
            return Settings(checks: false, downloads: false)
        case .check:
            return Settings(checks: true, downloads: false)
        case .download:
            return Settings(checks: true, downloads: installsAllowed)
        }
    }

    /// The user's choice on an available update, with `.install` turned
    /// into `.dismiss` when installs aren't allowed.
    static func gatedChoice(_ choice: SPUUserUpdateChoice, installsAllowed: Bool) -> SPUUserUpdateChoice {
        guard !installsAllowed, choice == .install else { return choice }
        return .dismiss
    }

    /// The answer to Sparkle's permission prompt, never turning automatic
    /// downloads on when installs aren't allowed.
    static func gatedPermission(_ response: SUUpdatePermissionResponse, installsAllowed: Bool) -> SUUpdatePermissionResponse {
        guard !installsAllowed, response.automaticUpdateDownloading?.boolValue == true else { return response }
        return SUUpdatePermissionResponse(
            automaticUpdateChecks: response.automaticUpdateChecks,
            automaticUpdateDownloading: NSNumber(value: false),
            sendSystemProfile: response.sendSystemProfile)
    }
}
