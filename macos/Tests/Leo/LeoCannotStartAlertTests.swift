import AppKit
import Foundation
import Testing

@testable import Ghostty

/// The "Leo can’t start" alert (D-069): the offending path shortened to
/// `…/<last folder>/<name>` so it doesn't wrap mid-word, a default Quit
/// button, and a Show in Finder button that reveals the file (or its folder
/// when the file isn't there) without dismissing the alert.
struct LeoCannotStartAlertTests {
    private static let lockPath = "/var/folders/ab/xyz_123/C/leo/studio.blackpaw.leo.macos.instance.lock"

    // MARK: - Path abbreviation

    @Test func aDeepPathShowsOnlyItsLastFolderAndName() {
        #expect(LeoCannotStartAlert.abbreviated(Self.lockPath) == "…/leo/studio.blackpaw.leo.macos.instance.lock")
        #expect(LeoCannotStartAlert.abbreviated("/var/folders/ab/xyz_123/C/leo") == "…/C/leo")
        #expect(LeoCannotStartAlert.abbreviated("/c/leo/x.instance.lock/") == "…/leo/x.instance.lock")
    }

    @Test(arguments: ["/leo/x.instance.lock", "/x.instance.lock", "/", "x.instance.lock", "../escape", ""])
    func aShortPathIsShownWhole(path: String) {
        #expect(LeoCannotStartAlert.abbreviated(path) == path)
    }

    /// Spaces and non-ASCII names survive; control and invisible formatting
    /// characters (a newline, a right-to-left override) can't reshape the
    /// alert text.
    @Test func unusualCharactersAreKeptVisibleAndControlsNeutralised() {
        #expect(LeoCannotStartAlert.abbreviated("/Users/Zoë Q/Caches/lëo dir/a b.lock") == "…/lëo dir/a b.lock")
        #expect(LeoCannotStartAlert.abbreviated("/a/b/le\no/x\u{202E}kcol.lock") == "…/le\u{FFFD}o/x\u{FFFD}kcol.lock")
    }

    // MARK: - Content

    @Test func theAlertNamesTheProblemWithTheShortPath() {
        let alert = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath), fileExists: { _ in true })

        #expect(alert.messageText == "Leo can’t start")
        #expect(alert.informativeText
            == "…/leo/studio.blackpaw.leo.macos.instance.lock has other hard links. Remove it and open Leo again.")
        #expect(!alert.informativeText.contains("/var/folders"))
    }

    @Test func anExistingFileIsRevealedItself() {
        let alert = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath), fileExists: { _ in true })

        #expect(alert.revealTarget?.path == Self.lockPath)
    }

    @Test func aMissingFileRevealsItsFolder() {
        var asked: [String] = []
        let alert = LeoCannotStartAlert(
            refusal: LeoInstanceLockRefusal(error: .system(EACCES), path: Self.lockPath),
            fileExists: { asked.append($0); return false }
        )

        #expect(alert.revealTarget?.path == "/var/folders/ab/xyz_123/C/leo")
        #expect(asked == [Self.lockPath])
    }

    /// No file behind the refusal (a bad bundle ID, no cache folder): nothing
    /// to reveal, so only Quit.
    @Test(arguments: [
        LeoInstanceLockRefusal(error: .invalidBundleIdentifier, path: "../escape"),
        LeoInstanceLockRefusal(error: .noCacheDirectory, path: "_CS_DARWIN_USER_CACHE_DIR"),
    ])
    func aRefusalWithoutAFileHasNoRevealTarget(refusal: LeoInstanceLockRefusal) {
        let alert = LeoCannotStartAlert(refusal: refusal, fileExists: { _ in Issue.record("must not stat"); return true })

        #expect(alert.revealTarget == nil)
        #expect(alert.informativeText == refusal.message)
    }

    // MARK: - Buttons

    @MainActor
    @Test func quitIsTheDefaultAndShowInFinderRevealsWithoutDismissing() throws {
        var revealed: [[String]] = []
        let content = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath), fileExists: { _ in true })
        let presenter = LeoCannotStartAlertPresenter(content: content, reveal: { revealed.append($0.map(\.path)) })

        let alert = presenter.makeAlert()

        #expect(alert.alertStyle == .critical)
        #expect(alert.messageText == content.messageText)
        #expect(alert.informativeText == content.informativeText)
        #expect(alert.buttons.map(\.title) == ["Quit", "Show in Finder"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        let show = alert.buttons[1]
        let target = try #require(show.target as? NSObject)
        let action = try #require(show.action)
        // Its own target, not NSAlert's, so the click never ends the modal.
        #expect(target !== alert)
        target.perform(action, with: show)
        #expect(revealed == [[Self.lockPath]])
    }

    @MainActor
    @Test func withoutARevealTargetThereIsOnlyQuit() {
        let content = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .noCacheDirectory, path: "_CS_DARWIN_USER_CACHE_DIR"), fileExists: { _ in true })

        let alert = LeoCannotStartAlertPresenter(content: content, reveal: { _ in Issue.record("must not reveal") }).makeAlert()

        #expect(alert.buttons.map(\.title) == ["Quit"])
    }

    // MARK: - Debug trigger

    #if DEBUG
    @Test func theDebugTriggerForcesARefusalOnTheRealLockPath() throws {
        let directory = URL(fileURLWithPath: "/c/leo", isDirectory: true)

        let refusal = try #require(LeoSingleInstance.forcedStartFailure(
            environment: ["LEO_FORCE_START_FAILURE": "1"], bundleIdentifier: "studio.blackpaw.leo.macos.debug", directory: directory
        ))

        #expect(refusal == LeoInstanceLockRefusal(error: .linked, path: "/c/leo/studio.blackpaw.leo.macos.debug.instance.lock"))
    }

    @Test(arguments: [[:], ["LEO_FORCE_START_FAILURE": "0"], ["LEO_FORCE_START_FAILURE": ""], ["OTHER": "1"]])
    func withoutTheDebugTriggerNothingIsForced(environment: [String: String]) {
        #expect(LeoSingleInstance.forcedStartFailure(
            environment: environment, bundleIdentifier: "studio.blackpaw.leo.macos.debug", directory: URL(fileURLWithPath: "/c/leo")
        ) == nil)
    }
    #endif
}
