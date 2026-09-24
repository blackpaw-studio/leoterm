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
        #expect(LeoCannotStartAlert.abbreviated("/a/b/l\u{2028}e\u{2029}o/x\u{85}y\u{0B}.lock")
            == "…/l\u{FFFD}e\u{FFFD}o/x\u{FFFD}y\u{FFFD}.lock")
    }

    /// The tooltip is text too: the full path is shown whole but neutralised
    /// the same way. Show in Finder still gets the real path.
    @MainActor
    @Test func theTooltipPathIsNeutralisedButTheRevealPathIsNot() throws {
        let path = "/a/b\u{2028}c/x\u{202E}.lock"
        var revealed: [[String]] = []
        let content = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: path))

        #expect(content.pathLine?.fullPath == "/a/b\u{FFFD}c/x\u{FFFD}.lock")
        let presenter = LeoCannotStartAlertPresenter(content: content, fileExists: { _ in true }, reveal: { revealed.append($0.map(\.path)) })
        let alert = presenter.makeAlert()
        #expect((alert.accessoryView as? NSTextField)?.toolTip == "/a/b\u{FFFD}c/x\u{FFFD}.lock")
        try withExtendedLifetime(presenter) { try Self.clickShowInFinder(alert) }
        #expect(revealed == [[path]])
    }

    // MARK: - Content

    /// The sentence never holds a path (a long file name wrapped and got
    /// hyphenated in it); the short path goes on its own line below.
    @Test func theSentenceNamesTheProblemAndThePathHasItsOwnLine() {
        let alert = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath))

        #expect(alert.messageText == "Leo can’t start")
        #expect(alert.informativeText == "Leo’s instance lock has other hard links. Remove it and open Leo again.")
        #expect(alert.pathLine == LeoCannotStartAlert.PathLine(
            text: "…/leo/studio.blackpaw.leo.macos.instance.lock", fullPath: Self.lockPath
        ))
    }

    @Test(arguments: [
        (LeoInstanceLockError.notARegularFile, "Leo’s instance lock is a symlink or not a regular file. Remove it and open Leo again."),
        (.notOwned, "Leo’s instance lock belongs to another user. Remove it and open Leo again."),
        (.system(EACCES), "Leo’s instance lock can’t be locked: Permission denied."),
        (.directory(.notADirectory), "Leo’s lock folder is a symlink or not a folder. Remove it and open Leo again."),
        (.directory(.notOwned), "Leo’s lock folder belongs to another user. Remove it and open Leo again."),
        (.directory(.unsafeParent), "The folder containing Leo’s lock folder can be changed by other users."),
        (.directory(.system(ENOENT)), "Leo’s lock folder can’t be checked: No such file or directory."),
    ])
    func everyFileRefusalSentenceIsPathFree(error: LeoInstanceLockError, sentence: String) {
        let alert = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: error, path: Self.lockPath))

        #expect(alert.informativeText == sentence)
        #expect(alert.pathLine?.fullPath == Self.lockPath)
    }

    @Test func anExistingFileIsRevealedItself() {
        let alert = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath))

        #expect(alert.revealTarget(fileExists: { _ in true })?.path == Self.lockPath)
    }

    @Test func aMissingFileRevealsItsFolder() {
        var asked: [String] = []
        let alert = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .system(EACCES), path: Self.lockPath))

        #expect(alert.revealTarget(fileExists: { asked.append($0); return false })?.path == "/var/folders/ab/xyz_123/C/leo")
        #expect(asked == [Self.lockPath])
    }

    /// No file behind the refusal (a bad bundle ID, no cache folder): nothing
    /// to reveal, so only Quit.
    @Test(arguments: [
        LeoInstanceLockRefusal(error: .invalidBundleIdentifier, path: "../escape"),
        LeoInstanceLockRefusal(error: .noCacheDirectory, path: "_CS_DARWIN_USER_CACHE_DIR"),
    ])
    func aRefusalWithoutAFileHasNoRevealTarget(refusal: LeoInstanceLockRefusal) {
        let alert = LeoCannotStartAlert(refusal: refusal)

        #expect(alert.revealTarget(fileExists: { _ in Issue.record("must not stat"); return true }) == nil)
        #expect(alert.pathLine == nil)
        #expect(alert.informativeText == refusal.message)
    }

    // MARK: - Buttons

    @MainActor
    @Test func quitIsTheDefaultAndShowInFinderRevealsWithoutDismissing() throws {
        var revealed: [[String]] = []
        let content = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath))
        let presenter = LeoCannotStartAlertPresenter(content: content, fileExists: { _ in true }, reveal: { revealed.append($0.map(\.path)) })

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

    /// The alert says to remove the file; if the user does and then clicks
    /// Show in Finder, the folder is revealed, not a file that's gone.
    @MainActor
    @Test func showInFinderChoosesFileOrFolderWhenClicked() throws {
        var exists = true
        var revealed: [[String]] = []
        let content = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath))
        let presenter = LeoCannotStartAlertPresenter(
            content: content, fileExists: { _ in exists }, reveal: { revealed.append($0.map(\.path)) }
        )
        let alert = presenter.makeAlert()

        exists = false
        try withExtendedLifetime(presenter) { try Self.clickShowInFinder(alert) }

        #expect(revealed == [["/var/folders/ab/xyz_123/C/leo"]])
    }

    @MainActor
    private static func clickShowInFinder(_ alert: NSAlert) throws {
        let show = try #require(alert.buttons.first { $0.title == "Show in Finder" })
        let target = try #require(show.target as? NSObject)
        target.perform(try #require(show.action), with: show)
    }

    @MainActor
    @Test func withoutARevealTargetThereIsOnlyQuit() {
        let content = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .noCacheDirectory, path: "_CS_DARWIN_USER_CACHE_DIR"))

        let alert = LeoCannotStartAlertPresenter(content: content, reveal: { _ in Issue.record("must not reveal") }).makeAlert()

        #expect(alert.buttons.map(\.title) == ["Quit"])
        #expect(alert.accessoryView == nil)
    }

    /// One selectable line, truncated in the middle rather than wrapped,
    /// the whole path in its tooltip, as wide as the alert's text.
    @MainActor
    @Test func thePathLineIsOneMiddleTruncatedSelectableLine() throws {
        let content = LeoCannotStartAlert(refusal: LeoInstanceLockRefusal(error: .linked, path: Self.lockPath))

        let alert = LeoCannotStartAlertPresenter(content: content, reveal: { _ in }).makeAlert()

        let label = try #require(alert.accessoryView as? NSTextField)
        #expect(label.stringValue == "…/leo/studio.blackpaw.leo.macos.instance.lock")
        #expect(label.toolTip == Self.lockPath)
        #expect(label.lineBreakMode == .byTruncatingMiddle)
        #expect(label.maximumNumberOfLines == 1)
        #expect(label.usesSingleLineMode)
        #expect(label.isSelectable)
        #expect(!label.isEditable)
        #expect(label.frame.width > 0)
        #expect(label.frame.width <= alert.window.frame.width)
        #expect(label.frame.height < 2 * label.intrinsicContentSize.height, "one line, not wrapped")
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
