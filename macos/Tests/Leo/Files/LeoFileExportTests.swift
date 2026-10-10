import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Downloading a workspace file to a Finder folder (B-279): streamed into
/// a private staging file, published without ever replacing anything, and
/// cleaned up on any failure so no partial file is left.
struct LeoFileExportTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp, .sftpSmallChunks]

    /// Runs `body` with a workspace sandbox (reached through `kind`) and a
    /// separate local drop folder.
    private func withExport(
        _ kind: LeoFileBackendKind,
        _ body: (LeoFileSandbox, any LeoFileAccess, LeoFileSandbox) async throws -> Void
    ) async throws {
        let drop = try LeoFileSandbox()
        defer { drop.cleanUp() }
        try await withLeoFileSandbox(kind) { workspace, access in
            try await body(workspace, access, drop)
        }
    }

    private func url(_ sandbox: LeoFileSandbox, _ name: String) -> URL {
        URL(fileURLWithPath: sandbox.path(name))
    }

    @Test(arguments: kinds)
    func downloadsAFileIntoTheDropDirectory(_ kind: LeoFileBackendKind) async throws {
        try await withExport(kind) { workspace, access, drop in
            let payload = leoPatternData(count: 150_000)
            try payload.write(to: url(workspace, "a.txt"))
            try workspace.chmod("a.txt", 0o600)

            let written = try await LeoFileExport.download(remotePath: workspace.path("a.txt"), to: url(drop, "a.txt"), access: access)

            #expect(written.lastPathComponent == "a.txt")
            #expect(try drop.names() == ["a.txt"])
            #expect(try Data(contentsOf: url(drop, "a.txt")) == payload)
            #expect(try drop.permissions("a.txt") == 0o644)
        }
    }

    @Test(arguments: kinds)
    func aNameClashKeepsBothAndNeverTouchesTheExisting(_ kind: LeoFileBackendKind) async throws {
        try await withExport(kind) { workspace, access, drop in
            try workspace.file("a.txt", "new")
            try drop.file("a.txt", "old")

            let second = try await LeoFileExport.download(remotePath: workspace.path("a.txt"), to: url(drop, "a.txt"), access: access)
            let third = try await LeoFileExport.download(remotePath: workspace.path("a.txt"), to: url(drop, "a.txt"), access: access)

            #expect(second.lastPathComponent == "a 2.txt")
            #expect(third.lastPathComponent == "a 3.txt")
            #expect(try drop.contents("a.txt") == "old")
            #expect(try drop.contents("a 2.txt") == "new")
            #expect(try drop.names() == ["a 2.txt", "a 3.txt", "a.txt"])
        }
    }

    @Test func aNameWithoutAnExtensionGetsItsNumberAtTheEnd() async throws {
        try await withExport(.local) { workspace, access, drop in
            try workspace.file(".env", "x")
            try drop.file(".env", "old")

            let written = try await LeoFileExport.download(remotePath: workspace.path(".env"), to: url(drop, ".env"), access: access)

            #expect(written.lastPathComponent == ".env 2")
        }
    }

    @Test func aDestinationSymlinkIsNeverFollowedOrReplaced() async throws {
        let outside = try LeoFileSandbox()
        defer { outside.cleanUp() }
        let target = try outside.file("target.txt", "outside")
        try await withExport(.local) { workspace, access, drop in
            try workspace.file("a.txt", "new")
            try drop.symlink("a.txt", to: target)

            let written = try await LeoFileExport.download(remotePath: workspace.path("a.txt"), to: url(drop, "a.txt"), access: access)

            #expect(written.lastPathComponent == "a 2.txt")
            #expect(try outside.contents("target.txt") == "outside")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drop.path("a.txt")) == target)
            #expect(try drop.contents("a 2.txt") == "new")
        }
    }

    @Test(arguments: kinds)
    func aMissingOrFolderSourceFailsBeforeCreatingAnything(_ kind: LeoFileBackendKind) async throws {
        try await withExport(kind) { workspace, access, drop in
            let folder = try workspace.directory("folder")
            let missing = workspace.path("missing.txt")

            await #expect(throws: LeoFileAccessError.notFound(path: missing)) {
                try await LeoFileExport.download(remotePath: missing, to: url(drop, "missing.txt"), access: access)
            }
            await #expect(throws: LeoFileAccessError.isADirectory(path: folder)) {
                try await LeoFileExport.download(remotePath: folder, to: url(drop, "folder"), access: access)
            }
            #expect(try drop.names().isEmpty)
        }
    }

    @Test(arguments: kinds)
    func aLocalWriteFailureMidStreamLeavesNoPartialFile(_ kind: LeoFileBackendKind) async throws {
        try await withExport(kind) { workspace, access, drop in
            try leoPatternData(count: 2 * kind.readWindowSize + 1).write(to: url(workspace, "a.txt"))
            let failure = LeoFileAccessError.failed(path: drop.path("a.txt"), reason: "No space left on device")

            await #expect(throws: failure) {
                try await LeoFileExport.download(remotePath: workspace.path("a.txt"), to: url(drop, "a.txt"), access: access) { offset in
                    if offset > 0 { throw failure }
                }
            }
            #expect(try drop.names().isEmpty)
            #expect(LeoFileExport.message(for: failure) == failure.localizedDescription)
        }
    }

    @Test(arguments: kinds)
    func cancellingADownloadRemovesItsStaging(_ kind: LeoFileBackendKind) async throws {
        try await withExport(kind) { workspace, access, drop in
            try leoPatternData(count: 3 * kind.readWindowSize).write(to: url(workspace, "a.txt"))
            let task = Task {
                try await LeoFileExport.download(remotePath: workspace.path("a.txt"), to: url(drop, "a.txt"), access: access) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }

            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try drop.names().isEmpty)
        }
    }

    @Test func anUnsafeDestinationNameIsRefused() async throws {
        let probe = LeoCountingAccess()
        let drop = try LeoFileSandbox()
        defer { drop.cleanUp() }

        for name in ["a\nb.txt", "..", "."] {
            await #expect(throws: LeoFileExport.ExportError.invalidName) {
                try await LeoFileExport.download(remotePath: "/w/a.txt", to: url(drop, name), access: probe)
            }
        }
        await #expect(throws: LeoFileExport.ExportError.invalidName) {
            try await LeoFileExport.download(remotePath: "/w/a.txt", to: URL(fileURLWithPath: drop.root + "/a/"), access: probe)
        }
        #expect(probe.calls == 0)
        #expect(try drop.names().isEmpty)
    }
}

/// Counts every call; answers none of them.
final class LeoCountingAccess: LeoFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    private func record(_ path: String) -> LeoFileAccessError {
        lock.withLock { count += 1 }
        return .notFound(path: path)
    }

    func list(_ path: String) async throws -> [LeoFileEntry] { throw record(path) }
    func stat(_ path: String) async throws -> LeoFileStat { throw record(path) }
    func homeDirectory() async throws -> String { throw record("~") }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { throw record(path) }
    func read(_ path: String, into sink: any LeoFileByteSink) async throws -> LeoFileStat { throw record(path) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat { throw record(path) }
    func close() async {}
}
