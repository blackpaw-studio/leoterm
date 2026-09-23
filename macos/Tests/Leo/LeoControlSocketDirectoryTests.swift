import Darwin
import Foundation
import Testing

@testable import Ghostty

/// The ControlMaster socket needs a path ssh can bind (86 bytes, see
/// `LeoSSHCommand.isValidControlPath`) whatever the home directory is,
/// in a directory no other local user can pre-create or swap out.
@Suite(.serialized)
struct LeoControlSocketDirectoryTests {
    private let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")

    /// A home directory longer than ~33 characters used to push the control
    /// path past the AF_UNIX budget and cost the host its file access.
    @MainActor @Test func aLongHomeDirectoryStillYieldsAUsableControlPath() throws {
        let home = "/Users/" + String(repeating: "h", count: 80)
        let defaults = try #require(UserDefaults(suiteName: "LeoControlSocketDirectoryTests.\(UUID().uuidString)"))
        let selection = LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            localSocketDirectory: URL(fileURLWithPath: home + "/.leo/state/leoterm", isDirectory: true)
        )

        let path = selection.controlPath(for: configuration)

        #expect(LeoSSHCommand.isValidControlPath(path), "\(path) (\(path.utf8.count) bytes)")
        #expect(!path.hasPrefix(home))
    }

    /// The per-user cache directory macOS creates owner-only for each user
    /// -- fixed length, independent of the home directory.
    @Test func theDefaultDirectoryIsThePerUserCacheDirectory() throws {
        let directory = try #require(LeoControlSocketDirectory.default)
        let base = directory.deletingLastPathComponent().path
        var info = Darwin.stat()

        #expect(stat(base, &info) == 0)
        #expect(info.st_uid == geteuid())
        #expect(info.st_mode & 0o077 == 0)
        #expect(directory.lastPathComponent == "leo")
    }

    @Test func prepareCreatesAnOwnerOnlyDirectory() throws {
        let directory = Self.makePath()
        defer { try? FileManager.default.removeItem(at: directory) }

        try LeoControlSocketDirectory.prepare(directory)

        #expect(Self.mode(directory) == 0o700)
    }

    @Test func prepareTightensALooseDirectoryItOwns() throws {
        let directory = Self.makePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])

        try LeoControlSocketDirectory.prepare(directory)

        #expect(Self.mode(directory) == 0o700)
    }

    /// A symlink planted at the directory's path is never followed.
    @Test func prepareRefusesASymlink() throws {
        let directory = Self.makePath()
        let target = Self.makePath()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)

        #expect(throws: LeoControlSocketDirectoryError.notADirectory) { try LeoControlSocketDirectory.prepare(directory) }
    }

    @Test func prepareRefusesAFile() throws {
        let directory = Self.makePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileManager.default.createFile(atPath: directory.path, contents: Data()))

        #expect(throws: LeoControlSocketDirectoryError.notADirectory) { try LeoControlSocketDirectory.prepare(directory) }
    }

    /// Another user pre-created the directory: never used, never chmodded.
    @Test func prepareRefusesADirectorySomeoneElseOwns() throws {
        let directory = Self.makePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])

        #expect(throws: LeoControlSocketDirectoryError.notOwned) {
            try LeoControlSocketDirectory.prepare(directory, owner: geteuid() + 1)
        }
        #expect(Self.mode(directory) == 0o777)
    }

    /// Anyone who can write the parent (without the sticky bit) could
    /// rename the checked directory away and put their own in its place.
    @Test func prepareRefusesAParentOthersCanRewrite() throws {
        let parent = Self.makePath()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        #expect(chmod(parent.path, 0o777) == 0)

        #expect(throws: LeoControlSocketDirectoryError.unsafeParent) {
            try LeoControlSocketDirectory.prepare(parent.appendingPathComponent("leo", isDirectory: true))
        }
    }

    /// `/tmp` itself is world-writable but sticky: others can't rename
    /// entries they don't own, so it's a safe parent.
    @Test func aStickyWorldWritableParentIsAccepted() throws {
        let directory = Self.makePath()
        defer { try? FileManager.default.removeItem(at: directory) }

        try LeoControlSocketDirectory.prepare(directory)
    }

    private static func makePath() -> URL {
        URL(fileURLWithPath: "/tmp/leocs-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private static func mode(_ url: URL) -> mode_t {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }
}
