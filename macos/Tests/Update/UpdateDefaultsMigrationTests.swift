import Testing
import Foundation
@testable import Ghostty

/// Every release before B-115 forced `automaticallyChecksForUpdates` off,
/// and Sparkle stored that as `SUEnableAutomaticChecks = NO`. A stored value
/// wins over Info.plist, so without a reset Sparkle would never ask.
struct UpdateDefaultsMigrationTests {
    private let suiteName = "UpdateDefaultsMigrationTests.\(UUID().uuidString)"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func clearsTheStoredOverrideOnce() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: "SUEnableAutomaticChecks")
            defaults.set(false, forKey: "SUAutomaticallyUpdate")

            UpdateDefaultsMigration.run(defaults)

            #expect(defaults.object(forKey: "SUEnableAutomaticChecks") == nil)
            #expect(defaults.object(forKey: "SUAutomaticallyUpdate") == nil)
            #expect(defaults.bool(forKey: UpdateDefaultsMigration.markerKey))
        }
    }

    /// After the reset, an answer the user gives Sparkle's prompt sticks.
    @Test func leavesALaterAnswerAlone() throws {
        try withDefaults { defaults in
            UpdateDefaultsMigration.run(defaults)
            defaults.set(false, forKey: "SUEnableAutomaticChecks")
            defaults.set(true, forKey: "SUAutomaticallyUpdate")

            UpdateDefaultsMigration.run(defaults)

            #expect(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
            #expect(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == true)
        }
    }

    @Test func freshInstallJustSetsTheMarker() throws {
        try withDefaults { defaults in
            UpdateDefaultsMigration.run(defaults)

            #expect(defaults.object(forKey: "SUEnableAutomaticChecks") == nil)
            #expect(defaults.bool(forKey: UpdateDefaultsMigration.markerKey))
        }
    }
}
