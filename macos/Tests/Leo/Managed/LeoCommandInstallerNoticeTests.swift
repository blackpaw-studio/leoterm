import Foundation
import Testing

@testable import Ghostty

/// What Leo ▸ "Install ‘leo’ Command…" tells the user for each outcome.
struct LeoCommandInstallerNoticeTests {
    private static let backup = URL(fileURLWithPath: "/home/test/.local/bin/leo.pre-leoapp")

    @Test func aDeclinedReplaceSaysNothing() {
        #expect(LeoCommandInstallerNotice.notice(for: .declined) == nil)
    }

    @Test func aFreshInstallNamesTheCommandAndSkipsTheHintWhenOnPath() throws {
        let notice = try #require(LeoCommandInstallerNotice.notice(for: .installed(pathHint: nil)))

        #expect(notice.style == .informational)
        #expect(notice.title == "‘leo’ command installed")
        #expect(notice.message.contains("~/.local/bin/leo"))
        #expect(!notice.message.contains("PATH"))
    }

    @Test func aMissingPathEntryIsExplainedInTheInstallNotice() throws {
        let notice = try #require(LeoCommandInstallerNotice.notice(for: .installed(pathHint: LeoCommandInstaller.pathHint)))

        #expect(notice.message.contains(LeoCommandInstaller.pathHint))
    }

    @Test func anUnverifiedPathIsWordedAsAConditionToCheck() throws {
        let notice = try #require(LeoCommandInstallerNotice.notice(for: .installed(pathHint: LeoCommandInstaller.unverifiedPathHint)))

        #expect(notice.message.contains("If ‘leo’ isn’t found"))
    }

    @Test func anExistingInstallIsReportedNotRedone() throws {
        let notice = try #require(LeoCommandInstallerNotice.notice(for: .alreadyInstalled))

        #expect(notice.style == .informational)
        #expect(notice.title == "‘leo’ command is already installed")
    }

    @Test(arguments: [
        (LeoCommandInstaller.Refusal.directory, "~/.local/bin/leo"),
        (.backupExists, "leo.pre-leoapp"),
        (.helperLinkMissing, "~/.leo/app/bin/leo"),
    ])
    func eachRefusalIsAWarningThatNamesTheThingInTheWay(refusal: LeoCommandInstaller.Refusal, mentions: String) throws {
        let notice = try #require(LeoCommandInstallerNotice.notice(for: .refused(refusal)))

        #expect(notice.style == .warning)
        #expect(notice.title == "Leo can’t install the ‘leo’ command")
        #expect(notice.message.contains(mentions))
    }

    @Test func theReplaceConfirmationNamesTheBackupAndPromisesNothingIsDeleted() {
        let notice = LeoCommandInstallerNotice.confirmReplace(backup: Self.backup)

        #expect(notice.message.contains("/home/test/.local/bin/leo.pre-leoapp"))
        #expect(notice.message.contains("not deleted"))
    }

    @Test func aFailureShowsTheUnderlyingError() {
        let notice = LeoCommandInstallerNotice.failure(LeoFileSystemError(operation: "symlink", path: "/x", code: EACCES))

        #expect(notice.style == .warning)
        #expect(notice.message.contains("Permission denied"))
    }
}
