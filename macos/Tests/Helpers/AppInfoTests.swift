import Testing
@testable import Ghostty

struct AppInfoTests {
    /// `Ghostty.Config.loadConfig` skips `ghostty_config_load_cli_args` when
    /// this is true, because in a test process the real argv (Xcode's
    /// debugger flags, or `-XCTest All <bundle>` from a host-app-injected
    /// run -- see .github/scripts/leo/run-unit-tests.sh) is not meaningful
    /// Ghostty CLI config and must never be parsed as such.
    @Test func detectsXCTestIsLoaded() {
        #expect(isRunningXCTest())
    }
}
