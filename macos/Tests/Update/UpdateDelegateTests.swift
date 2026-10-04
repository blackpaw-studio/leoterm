import Testing
import Foundation
import Sparkle
@testable import Ghostty

/// `UpdateDriver`'s Sparkle delegate adapter, `updater(_:mayPerform:)`, called
/// directly: it reads the updater's automatic-download setting and the
/// driver's install gate, and refuses a silent background check by throwing.
/// The updater is never started, so no check or network call happens.
@MainActor
struct UpdateDelegateTests {
    /// An updater that is never started and reports a fixed
    /// automatic-download setting instead of reading user defaults.
    private final class StubUpdater: SPUUpdater {
        private var downloads: Bool

        init(automaticallyDownloads: Bool, driver: UpdateDriver) {
            downloads = automaticallyDownloads
            super.init(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        }

        override var automaticallyDownloadsUpdates: Bool {
            get { downloads }
            set { downloads = newValue }
        }
    }

    private func driver(installsAllowed: Bool) -> UpdateDriver {
        UpdateDriver(
            viewModel: UpdateViewModel(),
            hostBundle: .main,
            installsAllowed: installsAllowed,
            hasUnobtrusiveTarget: { false })
    }

    private func mayPerform(
        _ check: SPUUpdateCheck,
        automaticallyDownloads: Bool,
        installsAllowed: Bool
    ) throws {
        let driver = driver(installsAllowed: installsAllowed)
        let updater = StubUpdater(automaticallyDownloads: automaticallyDownloads, driver: driver)
        try driver.updater(updater, mayPerform: check)
    }

    /// A debug build refuses a background check with automatic downloads on,
    /// with the adapter's error so Sparkle skips the check.
    @Test func debugRefusesASilentBackgroundCheckWithItsError() {
        let error = #expect(throws: NSError.self) {
            try mayPerform(.updatesInBackground, automaticallyDownloads: true, installsAllowed: false)
        }
        #expect(error?.domain == UpdateDriver.CheckRefusal.domain)
        #expect(error?.code == UpdateDriver.CheckRefusal.code)
        #expect(error?.localizedDescription == "This build can't install updates automatically.")
    }

    /// Every other check a debug build makes goes ahead.
    @Test(arguments: [
        (SPUUpdateCheck.updatesInBackground, false),
        (.updates, true),
        (.updates, false),
        (.updateInformation, true),
        (.updateInformation, false),
    ])
    func debugAllowsEveryOtherCheck(check: SPUUpdateCheck, automaticallyDownloads: Bool) {
        #expect(throws: Never.self) {
            try mayPerform(check, automaticallyDownloads: automaticallyDownloads, installsAllowed: false)
        }
    }

    /// A release build lets Sparkle download in the background.
    @Test func releaseAllowsASilentBackgroundCheck() {
        #expect(throws: Never.self) {
            try mayPerform(.updatesInBackground, automaticallyDownloads: true, installsAllowed: true)
        }
    }
}
