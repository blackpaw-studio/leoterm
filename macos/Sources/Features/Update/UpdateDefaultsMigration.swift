import Foundation

/// A one-time reset of the automatic-update answers Sparkle stored for
/// every release before B-115. Those builds forced
/// `automaticallyChecksForUpdates` (and downloads) off, which Sparkle saved
/// as `SUEnableAutomaticChecks = NO`; a stored value beats Info.plist, so
/// Sparkle would never ask. Nobody could have answered its prompt then, so
/// clearing both is safe. A marker makes this run once, so a later answer
/// (or `auto-update` value) sticks.
enum UpdateDefaultsMigration {
    static let markerKey = "LeoAutoUpdateDefaultsReset"
    static let staleKeys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]

    /// `defaults` is the domain Sparkle reads: the main bundle's
    /// `UserDefaults.standard`.
    static func run(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: markerKey) else { return }
        staleKeys.forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: markerKey)
    }
}
