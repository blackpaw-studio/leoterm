import Sparkle

/// How Leo drives Sparkle: the `auto-update` config maps to the updater's
/// automatic-check and automatic-download settings, and debug builds can
/// check for updates but never install one (B-115).
enum UpdatePolicy {
    /// Sparkle's automatic-update settings for one `auto-update` value.
    /// A nil field is left to Sparkle (its stored answer, or its prompt).
    struct Settings: Equatable {
        let checks: Bool?
        let downloads: Bool?
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

    /// The settings for `autoUpdate`. Unset leaves both to Sparkle, so its
    /// one-time permission prompt applies. Automatic downloads are forced
    /// off whenever installs aren't allowed, unset included.
    static func settings(for autoUpdate: Ghostty.Config.AutoUpdate?, installsAllowed: Bool) -> Settings {
        let forcedOff: Bool? = installsAllowed ? nil : false
        guard let autoUpdate else { return Settings(checks: nil, downloads: forcedOff) }
        switch autoUpdate {
        case .off:
            return Settings(checks: false, downloads: false)
        case .check:
            return Settings(checks: true, downloads: false)
        case .download:
            return Settings(checks: true, downloads: installsAllowed)
        }
    }

    /// The user's choice on an update at `stage`, gated when installs aren't
    /// allowed. Before a download, Install becomes Dismiss. Once an update is
    /// downloaded or installing, Dismiss would leave it staged to install on
    /// quit, so every choice becomes Skip, which cancels it.
    static func gatedChoice(
        _ choice: SPUUserUpdateChoice,
        stage: SPUUserUpdateStage,
        installsAllowed: Bool
    ) -> SPUUserUpdateChoice {
        guard !installsAllowed else { return choice }
        guard stage == .notDownloaded else { return .skip }
        return choice == .install ? .dismiss : choice
    }

    /// Whether Sparkle may run `check`. A background check with automatic
    /// downloads on runs Sparkle's silent driver, which downloads and
    /// installs on quit without asking the user driver, so no reply gate can
    /// stop it: refuse it when installs aren't allowed.
    static func mayCheck(_ check: SPUUpdateCheck, automaticallyDownloads: Bool, installsAllowed: Bool) -> Bool {
        installsAllowed || check != .updatesInBackground || !automaticallyDownloads
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
