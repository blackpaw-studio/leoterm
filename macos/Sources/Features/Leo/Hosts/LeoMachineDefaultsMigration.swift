import Foundation

/// Folds the single-host era's `leo.selectedHost` into the multi-machine
/// world: the host that was selected is the machine last used to spawn on.
/// Run once at launch; the old key is deleted either way, so a later run finds
/// nothing to do and can never overwrite a newer spawn choice.
struct LeoMachineDefaultsMigration {
    static let selectedHostKey = "leo.selectedHost"
    static let lastSpawnMachineKey = "leo.lastSpawnMachine"

    let defaults: UserDefaults

    /// Values keep `LeoHostID.displayName`'s spelling ("localhost" for This Mac).
    func run() {
        guard let selected = defaults.string(forKey: Self.selectedHostKey) else { return }
        if defaults.object(forKey: Self.lastSpawnMachineKey) == nil {
            defaults.set(selected, forKey: Self.lastSpawnMachineKey)
        }
        defaults.removeObject(forKey: Self.selectedHostKey)
    }
}
