/// The launch-time order of Leo's update setup, kept in one place so a test
/// can pin it (B-126). The steps are injected so the test never starts
/// Sparkle's updater (D-224).
enum UpdateLaunchSequence {
    /// Runs `resetDefaults`, then `applyConfig`, then `startUpdater`.
    ///
    /// The reset must come first. `applyConfig` sets the updater's
    /// automatic-update properties from `auto-update`, which Sparkle saves to
    /// the same defaults keys the reset clears, so a later reset would erase
    /// the user's config for that launch. `startUpdater` makes Sparkle read
    /// those keys and decide whether to show its permission prompt, so a reset
    /// after it would leave a pre-B-115 install never asked (D-221).
    static func run(
        resetDefaults: () -> Void,
        applyConfig: () -> Void,
        startUpdater: () -> Void
    ) {
        resetDefaults()
        applyConfig()
        startUpdater()
    }
}
