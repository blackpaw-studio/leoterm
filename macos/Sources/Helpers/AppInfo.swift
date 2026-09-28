import Foundation

/// True if we appear to be running in Xcode.
func isRunningInXcode() -> Bool {
    ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
}

/// True if an XCTest bundle is loaded into this process -- whether launched
/// normally by `xcodebuild test`, or injected into a running copy of this
/// app's own binary (see .github/scripts/leo/run-unit-tests.sh, which passes
/// `-XCTest All <bundle>` on argv to trigger the injected test runner). In
/// either case the process's real argv is test-harness plumbing, not
/// something a user typed, and must not be parsed as Ghostty CLI config.
func isRunningXCTest() -> Bool {
    NSClassFromString("XCTestCase") != nil
}
