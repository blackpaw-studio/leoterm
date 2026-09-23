import Foundation
import Testing

@testable import Ghostty

/// The shared behavioural contract for `LeoFileAccess`: listing, stat,
/// reading and error mapping. Every test runs once per backend
/// (`LeoFileBackendKind`), so local and remote are held to the same bar.
/// Writes live in `LeoFileAccessWriteContractTests`.
@Suite(LeoSSHEndToEnd.trait)
struct LeoFileAccessContractTests {
    @Test(arguments: LeoFileBackendKind.allCases)
    func listsEntriesSortedByNameWithKindSizeAndTime(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try sandbox.file("b.txt", "hello")
            try sandbox.directory("a")
            try sandbox.symlink("c", to: "b.txt")
            try sandbox.file(".hidden", "")

            let entries = try await access.list(sandbox.root)

            #expect(entries.map(\.name) == [".hidden", "a", "b.txt", "c"])
            #expect(entries.map(\.kind) == [.file, .directory, .file, .symlink])
            #expect(entries[2].size == 5)
            let onDisk = try FileManager.default.attributesOfItem(atPath: sandbox.path("b.txt"))[.modificationDate] as? Date
            #expect(abs(entries[2].modified.timeIntervalSince(try #require(onDisk))) < 1)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func listsThroughASymlinkedDirectory(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try sandbox.directory("real")
            try sandbox.file("real/inside.txt", "x")
            let link = try sandbox.symlink("link", to: sandbox.path("real"))

            #expect(try await access.list(link).map(\.name) == ["inside.txt"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func listingAFileIsNotADirectory(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let file = try sandbox.file("f.txt", "x")
            await #expect(throws: LeoFileAccessError.notADirectory(path: file)) { try await access.list(file) }
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func statReportsKindSizePermissionsAndFollowsSymlinks(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let file = try sandbox.file("f.txt", "12345678", permissions: 0o640)
            let link = try sandbox.symlink("link", to: file)
            let directory = try sandbox.directory("d")

            let stat = try await access.stat(file)
            #expect(stat.kind == .file)
            #expect(stat.size == 8)
            #expect(stat.permissions == 0o640)
            #expect(try await access.stat(link).kind == .file)
            #expect(try await access.stat(directory).kind == .directory)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func readReturnsBytesWithTheStatTakenBeforeReading(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let file = try sandbox.file("f.txt", "hello, world")

            let contents = try await access.read(file, maxBytes: 1024)

            #expect(contents.data == Data("hello, world".utf8))
            #expect(contents.stat.size == 12)
            #expect(contents.stat.version == (try await access.stat(file)).version)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func readRefusesFilesOverTheSizeCap(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let file = try sandbox.file("big.txt", String(repeating: "x", count: 100))

            await #expect(throws: LeoFileAccessError.tooLarge(path: file, size: 100, limit: 99)) {
                try await access.read(file, maxBytes: 99)
            }
            #expect(try await access.read(file, maxBytes: 100).data.count == 100)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func readingADirectoryIsADirectory(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let directory = try sandbox.directory("d")
            await #expect(throws: LeoFileAccessError.isADirectory(path: directory)) {
                try await access.read(directory, maxBytes: 10)
            }
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func missingPathsAreNotFoundForEveryOperation(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let missing = sandbox.path("nope")
            let expected = LeoFileAccessError.notFound(path: missing)
            await #expect(throws: expected) { try await access.stat(missing) }
            await #expect(throws: expected) { try await access.read(missing, maxBytes: 10) }
            await #expect(throws: expected) { try await access.list(missing) }

            let inMissingDirectory = sandbox.path("nope/file.txt")
            await #expect(throws: LeoFileAccessError.notFound(path: inMissingDirectory)) {
                try await access.write(Data("x".utf8), to: inMissingDirectory, expecting: nil)
            }
        }
    }

    /// OpenSSH answers ENAMETOOLONG with a bare "Bad message"; the remote
    /// error must read like the local one.
    @Test(arguments: LeoFileBackendKind.allCases)
    func aNameTooLongReadsTheSameForEveryOperation(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let long = sandbox.path(String(repeating: "n", count: 300))
            let expected = LeoFileAccessError.failed(path: long, reason: "File name too long")
            await #expect(throws: expected) { try await access.stat(long) }
            await #expect(throws: expected) { try await access.read(long, maxBytes: 10) }
            await #expect(throws: expected) { try await access.list(long) }
            await #expect(throws: expected) { try await access.write(Data("x".utf8), to: long, expecting: nil) }
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func unreadableFilesAndDirectoriesArePermissionDenied(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let file = try sandbox.file("secret.txt", "x", permissions: 0o000)
            let directory = try sandbox.directory("locked")
            try sandbox.chmod("locked", 0o000)

            await #expect(throws: LeoFileAccessError.permissionDenied(path: file)) {
                try await access.read(file, maxBytes: 10)
            }
            await #expect(throws: LeoFileAccessError.permissionDenied(path: directory)) {
                try await access.list(directory)
            }
        }
    }

    /// `~` in a surfaced path means the agent's host's home, local or remote.
    @Test(arguments: LeoFileBackendKind.allCases)
    func homeDirectoryIsTheHostUsersHome(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { _, access in
            let home = try await access.homeDirectory()

            #expect(home.hasPrefix("/"))
            #expect(try await access.stat(home).kind == .directory)
            if kind != .sshEndToEnd { #expect(home == NSHomeDirectory()) }
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func relativePathsAreRejectedBeforeTouchingTheBackend(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { _, access in
            await #expect(throws: LeoFileAccessError.invalidPath("relative.txt")) { try await access.stat("relative.txt") }
            await #expect(throws: LeoFileAccessError.invalidPath("")) { try await access.list("") }
            await #expect(throws: LeoFileAccessError.invalidPath("/a\0b")) { try await access.read("/a\0b", maxBytes: 1) }
        }
    }
}
