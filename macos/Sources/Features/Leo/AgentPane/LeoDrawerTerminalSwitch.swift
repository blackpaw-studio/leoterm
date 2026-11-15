import Combine

/// What turning "Show Terminal tab" off does to running shells: they are
/// closed (every window's), so none keeps running out of reach and turning the
/// switch back on brings nothing old back. Turning it on spawns nothing: a
/// shell starts only when the tab is opened.
enum LeoDrawerTerminalSwitch {
    @MainActor static func closeShellsWhenTurnedOff(
        settings: LeoBuiltInPaneSettings, closeAll: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        settings.$showsTerminalTab
            .dropFirst()
            .removeDuplicates()
            .filter { !$0 }
            .sink { _ in MainActor.assumeIsolated { closeAll() } }
    }
}
