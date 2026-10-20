import Foundation
import Testing

@testable import Ghostty

struct LeoCommandInstallerTests {
    private static let paths = LeoInstallPaths(
        home: URL(fileURLWithPath: "/home/test", isDirectory: true),
        bundleURL: URL(fileURLWithPath: "/Applications/Leo.app")
    )
    private static let selfLink = "/home/test/.leo/app/bin/leo"
    private static let command = "/home/test/.local/bin/leo"
    private static let backup = URL(fileURLWithPath: "/home/test/.local/bin/leo.pre-leoapp")

    private func makeInstaller(selfLinkPresent: Bool = true) -> (LeoCommandInstaller, LeoInMemoryFileSystem) {
        let fileSystem = LeoInMemoryFileSystem()
        if selfLinkPresent { fileSystem.addSymlink(Self.selfLink, to: "/Applications/Leo.app/Contents/Helpers/leo") }
        return (LeoCommandInstaller(paths: Self.paths, fileSystem: fileSystem), fileSystem)
    }

    // MARK: plan table

    @Test func planIsCreateWhenNothingIsThere() {
        #expect(makeInstaller().0.plan() == .create)
    }

    @Test func planIsAlreadyInstalledForOurSymlink() {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addSymlink(Self.command, to: Self.selfLink)
        #expect(installer.plan() == .alreadyInstalled)
    }

    @Test func planAsksBeforeReplacingAForeignSymlink() {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addSymlink(Self.command, to: "/opt/homebrew/bin/leo")
        #expect(installer.plan() == .confirmReplace(backup: Self.backup))
    }

    @Test func planAsksBeforeReplacingARealFile() {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addFile(Self.command, "curl-installed", mode: 0o755)
        #expect(installer.plan() == .confirmReplace(backup: Self.backup))
    }

    @Test func planRefusesADirectory() {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addDirectory(Self.command)
        #expect(installer.plan() == .refuse(.directory))
    }

    @Test func planRefusesToClobberAnEarlierBackup() {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addFile(Self.command)
        fileSystem.addFile(Self.backup.path, "original")
        #expect(installer.plan() == .refuse(.backupExists))
    }

    @Test func planRefusesWhenThereIsNoHelperLinkToPointAt() {
        #expect(makeInstaller(selfLinkPresent: false).0.plan() == .refuse(.helperLinkMissing))
    }

    // MARK: install

    @Test func createMakesLocalBinAndLinksToTheStableSelfLinkNotTheBundle() async throws {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.clearLog()

        let outcome = try await installer.install(confirmReplace: { _ in Issue.record("must not ask"); return false }, path: "/usr/bin")

        #expect(outcome == .installed(pathHint: LeoCommandInstaller.pathHint))
        #expect(fileSystem.ops == [
            .createDirectory("/home/test/.local/bin", mode: 0o755),
            .symlink(Self.command, target: Self.selfLink)
        ])
    }

    @Test func noPathHintWhenLocalBinIsOnPath() async throws {
        let (installer, _) = makeInstaller()
        let outcome = try await installer.install(confirmReplace: { _ in false }, path: "/usr/bin:/home/test/.local/bin")
        #expect(outcome == .installed(pathHint: nil))
    }

    @Test func existingLocalBinIsNotRecreated() async throws {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addDirectory("/home/test/.local/bin")
        fileSystem.clearLog()

        _ = try await installer.install(confirmReplace: { _ in false }, path: nil)

        #expect(fileSystem.ops == [.symlink(Self.command, target: Self.selfLink)])
    }

    @Test func confirmedReplaceMovesTheOriginalToTheBackupThenLinks() async throws {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addFile(Self.command, "curl-installed", mode: 0o755)
        fileSystem.clearLog()
        let asked = AskLog()

        let outcome = try await installer.install(confirmReplace: { backup in await asked.record(backup); return true }, path: "/home/test/.local/bin")

        #expect(outcome == .installed(pathHint: nil))
        #expect(await asked.backups == [Self.backup])
        #expect(fileSystem.ops == [
            .move(Self.command, Self.backup.path),
            .symlink(Self.command, target: Self.selfLink)
        ])
        #expect(fileSystem.contents(of: Self.backup.path) == "curl-installed")
    }

    @Test func declinedReplaceChangesNothing() async throws {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addFile(Self.command)
        fileSystem.clearLog()

        let outcome = try await installer.install(confirmReplace: { _ in false }, path: nil)

        #expect(outcome == .declined)
        #expect(fileSystem.ops.isEmpty)
    }

    @Test func aFailedLinkAfterTheBackupRestoresTheOriginal() async throws {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addFile(Self.command, "curl-installed")
        fileSystem.failNext("symlink", at: Self.command)
        fileSystem.clearLog()

        await #expect(throws: LeoFileSystemError.self) { try await installer.install(confirmReplace: { _ in true }, path: nil) }

        #expect(fileSystem.ops == [
            .move(Self.command, Self.backup.path),
            .move(Self.backup.path, Self.command)
        ])
        #expect(fileSystem.contents(of: Self.command) == "curl-installed")
    }

    @Test func alreadyInstalledAndRefusalsTouchNothing() async throws {
        let (installer, fileSystem) = makeInstaller()
        fileSystem.addSymlink(Self.command, to: Self.selfLink)
        fileSystem.clearLog()
        #expect(try await installer.install(confirmReplace: { _ in true }, path: nil) == .alreadyInstalled)

        let (refusing, refusingFileSystem) = makeInstaller()
        refusingFileSystem.addDirectory(Self.command)
        refusingFileSystem.clearLog()
        #expect(try await refusing.install(confirmReplace: { _ in true }, path: nil) == .refused(.directory))

        #expect(fileSystem.ops.isEmpty)
        #expect(refusingFileSystem.ops.isEmpty)
    }
}

private actor AskLog {
    private(set) var backups: [URL] = []
    func record(_ backup: URL) { backups.append(backup) }
}
