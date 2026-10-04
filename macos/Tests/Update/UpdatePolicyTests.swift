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
        #expect(UpdatePolicy.settings(for: nil, installsAllowed: true) == Settings(checks: nil, downloads: nil))
    }

    /// Debug still leaves the check setting to Sparkle when unset, but
    /// automatic downloads are always forced off.
    @Test func unsetInDebugStillForcesDownloadsOff() {
        #expect(UpdatePolicy.settings(for: nil, installsAllowed: false) == Settings(checks: nil, downloads: false))
    }

    @Test func debugNeverAutoDownloads() {
        #expect(UpdatePolicy.settings(for: .download, installsAllowed: false) == Settings(checks: true, downloads: false))
        #expect(UpdatePolicy.settings(for: .check, installsAllowed: false) == Settings(checks: true, downloads: false))
        #expect(UpdatePolicy.settings(for: .off, installsAllowed: false) == Settings(checks: false, downloads: false))
    }

    /// Nothing is downloaded yet: Install becomes Dismiss, and the other
    /// choices pass through.
    @Test func debugGateTurnsInstallIntoDismissBeforeDownload() {
        let stage = SPUUserUpdateStage.notDownloaded
        #expect(UpdatePolicy.gatedChoice(.install, stage: stage, installsAllowed: false) == .dismiss)
        #expect(UpdatePolicy.gatedChoice(.skip, stage: stage, installsAllowed: false) == .skip)
        #expect(UpdatePolicy.gatedChoice(.dismiss, stage: stage, installsAllowed: false) == .dismiss)
    }

    /// Once an update is downloaded or installing, Dismiss would keep it
    /// staged to install on quit; only Skip cancels it.
    @Test(arguments: [SPUUserUpdateStage.downloaded, .installing])
    func debugGateSkipsAStagedUpdate(stage: SPUUserUpdateStage) {
        for choice in [SPUUserUpdateChoice.install, .dismiss, .skip] {
            #expect(UpdatePolicy.gatedChoice(choice, stage: stage, installsAllowed: false) == .skip)
        }
    }

    @Test(arguments: [SPUUserUpdateStage.notDownloaded, .downloaded, .installing])
    func releaseChoicesPassThrough(stage: SPUUserUpdateStage) {
        for choice in [SPUUserUpdateChoice.install, .dismiss, .skip] {
            #expect(UpdatePolicy.gatedChoice(choice, stage: stage, installsAllowed: true) == choice)
        }
    }

    @Test func debugPermissionNeverEnablesDownloads() {
        let asked = SUUpdatePermissionResponse(
            automaticUpdateChecks: true, automaticUpdateDownloading: NSNumber(value: true), sendSystemProfile: false)

        let gated = UpdatePolicy.gatedPermission(asked, installsAllowed: false)
        #expect(gated.automaticUpdateChecks)
        #expect(gated.automaticUpdateDownloading?.boolValue == false)
        #expect(UpdatePolicy.gatedPermission(asked, installsAllowed: true).automaticUpdateDownloading?.boolValue == true)
    }

    /// A background check with automatic downloads on runs Sparkle's silent
    /// download-and-install-on-quit driver, which no reply gate can stop, so
    /// a debug build refuses it. Every other check proceeds.
    @Test func debugRefusesSilentBackgroundDownloads() {
        #expect(!UpdatePolicy.mayCheck(.updatesInBackground, automaticallyDownloads: true, installsAllowed: false))
        #expect(UpdatePolicy.mayCheck(.updatesInBackground, automaticallyDownloads: false, installsAllowed: false))
        #expect(UpdatePolicy.mayCheck(.updates, automaticallyDownloads: true, installsAllowed: false))
        #expect(UpdatePolicy.mayCheck(.updateInformation, automaticallyDownloads: true, installsAllowed: false))
        #expect(UpdatePolicy.mayCheck(.updatesInBackground, automaticallyDownloads: true, installsAllowed: true))
    }

    /// Debug builds (this test host, when built Debug) never install;
    /// release builds do.
    @Test func installsFollowTheBuildConfiguration() {
        #if DEBUG
        #expect(!UpdatePolicy.installsAllowed)
        #else
        #expect(UpdatePolicy.installsAllowed)
        #endif
    }

    /// The app's Info.plist no longer forces automatic checks off, so the
    /// `auto-update` config (or Sparkle's permission prompt) decides; the
    /// signing key Sparkle verifies downloads with is still there.
    @Test func infoPlistNoLongerDisablesChecks() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUEnableAutomaticChecks"] == nil)
        #expect((info["SUPublicEDKey"] as? String)?.isEmpty == false)
    }

    /// Sparkle's standard alerts (the update-found alert, still used when no
    /// terminal window can host the pill, and its permission prompt) show an
    /// "Automatically download and install updates" checkbox unless the
    /// host's `allowsAutomaticUpdates` is off. A build that can't install
    /// must never offer it, so Debug's Info.plist turns it off (B-129).
    @Test func buildsThatCantInstallNeverOfferAutomaticInstalls() {
        guard !UpdatePolicy.installsAllowed else { return }
        let settings = SPUUpdaterSettings(hostBundle: .main)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false)
        #expect(!settings.allowsAutomaticUpdates)
        #expect(!settings.automaticallyDownloadsUpdates)
    }
}
