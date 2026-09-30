import Testing
import Foundation
import Sparkle
@testable import Ghostty

struct UpdatePolicyTests {
    typealias Settings = UpdatePolicy.Settings

    @Test func offDisablesChecksAndDownloads() {
        #expect(UpdatePolicy.settings(for: .off, installsAllowed: true) == Settings(checks: false, downloads: false))
    }

    @Test func checkEnablesChecksOnly() {
        #expect(UpdatePolicy.settings(for: .check, installsAllowed: true) == Settings(checks: true, downloads: false))
    }

    @Test func downloadEnablesBoth() {
        #expect(UpdatePolicy.settings(for: .download, installsAllowed: true) == Settings(checks: true, downloads: true))
    }

    /// Unset leaves Sparkle's own settings alone, so its one-time
    /// "check automatically?" permission prompt applies.
    @Test func unsetDefersToSparkle() {
        #expect(UpdatePolicy.settings(for: nil, installsAllowed: true) == nil)
        #expect(UpdatePolicy.settings(for: nil, installsAllowed: false) == nil)
    }

    @Test func debugNeverAutoDownloads() {
        #expect(UpdatePolicy.settings(for: .download, installsAllowed: false) == Settings(checks: true, downloads: false))
        #expect(UpdatePolicy.settings(for: .check, installsAllowed: false) == Settings(checks: true, downloads: false))
        #expect(UpdatePolicy.settings(for: .off, installsAllowed: false) == Settings(checks: false, downloads: false))
    }

    @Test func debugGateTurnsInstallIntoDismiss() {
        #expect(UpdatePolicy.gatedChoice(.install, installsAllowed: false) == .dismiss)
        #expect(UpdatePolicy.gatedChoice(.skip, installsAllowed: false) == .skip)
        #expect(UpdatePolicy.gatedChoice(.dismiss, installsAllowed: false) == .dismiss)
        #expect(UpdatePolicy.gatedChoice(.install, installsAllowed: true) == .install)
    }

    @Test func debugPermissionNeverEnablesDownloads() {
        let asked = SUUpdatePermissionResponse(
            automaticUpdateChecks: true, automaticUpdateDownloading: NSNumber(value: true), sendSystemProfile: false)

        let gated = UpdatePolicy.gatedPermission(asked, installsAllowed: false)
        #expect(gated.automaticUpdateChecks)
        #expect(gated.automaticUpdateDownloading?.boolValue == false)
        #expect(UpdatePolicy.gatedPermission(asked, installsAllowed: true).automaticUpdateDownloading?.boolValue == true)
    }

    /// This suite runs in a Debug test host: installs are off.
    @Test func debugBuildDisallowsInstalls() {
        #expect(!UpdatePolicy.installsAllowed)
    }

    /// The app's Info.plist no longer forces automatic checks off, so the
    /// `auto-update` config (or Sparkle's permission prompt) decides; the
    /// signing key Sparkle verifies downloads with is still there.
    @Test func infoPlistNoLongerDisablesChecks() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUEnableAutomaticChecks"] == nil)
        #expect((info["SUPublicEDKey"] as? String)?.isEmpty == false)
    }
}
