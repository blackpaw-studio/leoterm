import Foundation
import Testing

@testable import Ghostty

/// Runs the real implementation against a scratch directory (never `~/.leo`).
struct LeoDiskFileSystemTests {
    private let root: URL
    private let fileSystem = LeoDiskFileSystem(makeToken: { "tok" })

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("leo-disk-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @Test func atomicWriteSetsExactModeDespiteUmaskAndLeavesNoTempFile() throws {
        defer { cleanUp() }
        let target = root.appendingPathComponent("a/b/managed.json")
        try fileSystem.createDirectory(at: target.deletingLastPathComponent(), mode: 0o700)
        let previous = umask(0o077)
        defer { umask(previous) }

        try fileSystem.writeAtomically(Data("{}".utf8), to: target, mode: 0o640)

        #expect(try fileSystem.read(target) == Data("{}".utf8))
        #expect(fileSystem.mode(at: target) == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["managed.json"])
    }

    @Test func createDirectoryAppliesModeToTheLeafAndIsIdempotent() throws {
        defer { cleanUp() }
        let leaf = root.appendingPathComponent("x/state")

        try fileSystem.createDirectory(at: leaf, mode: 0o700)
        try fileSystem.createDirectory(at: leaf, mode: 0o755)

        #expect(fileSystem.kind(at: leaf) == .directory)
        #expect(fileSystem.mode(at: leaf) == 0o700)
        #expect(fileSystem.mode(at: root.appendingPathComponent("x")) == 0o755)
    }

    @Test func replaceSymlinkAtomicallySwapsTheTargetWithoutFollowingIt() throws {
        defer { cleanUp() }
        let link = root.appendingPathComponent("leo")
        try fileSystem.symlink(at: link, to: "/old/leo")

        try fileSystem.replaceSymlinkAtomically(at: link, to: "/new/leo")

        #expect(fileSystem.kind(at: link) == .symlink(target: "/new/leo"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["leo"])
    }

    @Test func kindDoesNotFollowSymlinksAndReportsDanglingOnes() throws {
        defer { cleanUp() }
        let dir = root.appendingPathComponent("d")
        let file = root.appendingPathComponent("f")
        try fileSystem.createDirectory(at: dir, mode: 0o755)
        try fileSystem.writeAtomically(Data(), to: file, mode: 0o600)
        try fileSystem.symlink(at: root.appendingPathComponent("to-dir"), to: dir.path)
        try fileSystem.symlink(at: root.appendingPathComponent("dangling"), to: "/nonexistent")

        #expect(fileSystem.kind(at: dir) == .directory)
        #expect(fileSystem.kind(at: file) == .file)
        #expect(fileSystem.kind(at: root.appendingPathComponent("to-dir")) == .symlink(target: dir.path))
        #expect(fileSystem.kind(at: root.appendingPathComponent("dangling")) == .symlink(target: "/nonexistent"))
        #expect(fileSystem.kind(at: root.appendingPathComponent("nope")) == .absent)
    }

    @Test func removeUnlinksASymlinkWithoutTouchingItsTarget() throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("f")
        try fileSystem.writeAtomically(Data("x".utf8), to: file, mode: 0o600)
        let link = root.appendingPathComponent("l")
        try fileSystem.symlink(at: link, to: file.path)

        try fileSystem.remove(link)

        #expect(fileSystem.kind(at: link) == .absent)
        #expect(fileSystem.kind(at: file) == .file)
    }

    @Test func sha256MatchesKnownDigest() throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("abc")
        try fileSystem.writeAtomically(Data("abc".utf8), to: file, mode: 0o600)

        #expect(try fileSystem.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func copyRefusesToOverwriteAndMoveReplaces() throws {
        defer { cleanUp() }
        let source = root.appendingPathComponent("s")
        let destination = root.appendingPathComponent("d")
        try fileSystem.writeAtomically(Data("new".utf8), to: source, mode: 0o755)
        try fileSystem.writeAtomically(Data("old".utf8), to: destination, mode: 0o755)

        #expect(throws: (any Error).self) { try fileSystem.copyFile(from: source, to: destination) }
        try fileSystem.move(from: source, to: destination)

        #expect(try fileSystem.read(destination) == Data("new".utf8))
        #expect(fileSystem.kind(at: source) == .absent)
    }

    @Test func moveWithoutReplacingRefusesAnOccupiedDestinationAndMovesIntoAFreeOne() throws {
        defer { cleanUp() }
        let source = root.appendingPathComponent("s")
        let taken = root.appendingPathComponent("taken")
        let free = root.appendingPathComponent("free")
        try fileSystem.writeAtomically(Data("new".utf8), to: source, mode: 0o755)
        try fileSystem.writeAtomically(Data("old".utf8), to: taken, mode: 0o755)

        #expect(throws: LeoFileSystemError(operation: "rename", path: taken.path, code: EEXIST)) {
            try fileSystem.moveWithoutReplacing(from: source, to: taken)
        }
        #expect(try fileSystem.read(taken) == Data("old".utf8))
        #expect(try fileSystem.read(source) == Data("new".utf8))

        try fileSystem.moveWithoutReplacing(from: source, to: free)
        #expect(try fileSystem.read(free) == Data("new".utf8))
        #expect(fileSystem.kind(at: source) == .absent)
    }

    @Test func symlinkRefusesAnOccupiedPath() throws {
        defer { cleanUp() }
        let link = root.appendingPathComponent("l")
        try fileSystem.symlink(at: link, to: "/a")

        #expect(throws: LeoFileSystemError(operation: "symlink", path: link.path, code: EEXIST)) {
            try fileSystem.symlink(at: link, to: "/b")
        }
        #expect(fileSystem.kind(at: link) == .symlink(target: "/a"))
    }

    @Test func failuresCarryOperationPathAndReason() {
        defer { cleanUp() }
        let missing = root.appendingPathComponent("nope/child")
        #expect(throws: LeoFileSystemError(operation: "symlink", path: missing.path, code: ENOENT)) {
            try fileSystem.symlink(at: missing, to: "/x")
        }
    }
}
