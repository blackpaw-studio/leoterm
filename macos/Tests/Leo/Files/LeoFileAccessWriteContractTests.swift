import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The shared write contract for `LeoFileAccess`: atomic replace, permission
/// preservation, symlinks, conflict detection and large files. Runs once per
/// backend, like `LeoFileAccessContractTests`.
@Suite(.hostOnly, LeoSSHEndToEnd.trait)
struct LeoFileAccessWriteContractTests {
    @Test(arguments: LeoFileBackendKind.allCases)
    func createsExclusivelyWithoutReplacingAClash(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let newPath = sandbox.path("new.txt")
            let existingPath = try sandbox.file("existing.txt", "keep me")

            let stat = try await access.create(Data("new".utf8), at: newPath)

            #expect(stat.kind == .file)
            #expect(try sandbox.contents("new.txt") == "new")
            await #expect(throws: LeoFileAccessError.conflict(path: existingPath)) {
                try await access.create(Data("replacement".utf8), at: existingPath)
            }
            #expect(try sandbox.contents("existing.txt") == "keep me")
            #expect(try sandbox.names() == ["existing.txt", "new.txt"])
        }
    }

    /// The source fails after its first chunk: no destination and no hidden
    /// staging sibling may be left behind.
    @Test(arguments: LeoFileBackendKind.allCases)
    func createRemovesStagingWhenSourceFailsMidStream(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let source = LeoFailingByteSource(prefix: leoPatternData(count: kind.writeChunkSize), failAt: UInt64(kind.writeChunkSize))

            await #expect(throws: LeoFileAccessError.self) {
                try await access.create(at: sandbox.path("half.bin"), from: source)
            }

            let names = try sandbox.names()
            #expect(names.isEmpty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func createPublishesThroughTheNamedStaging(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = sandbox.path("x.pdf")
            let staging = LeoFileName.stagingPath(for: path)

            try await access.create(at: path, from: Data("pdf".utf8), staging: staging)

            #expect(try sandbox.contents("x.pdf") == "pdf")
            #expect(try sandbox.names() == ["x.pdf"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func createRefusesAStagingThatIsNotAHiddenSibling(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try sandbox.directory("other")
            let path = sandbox.path("x.pdf")
            for staging in [sandbox.path("y.pdf"), LeoFileName.stagingPath(for: sandbox.path("other/x.pdf"))] {
                await #expect(throws: LeoFileAccessError.invalidPath(staging)) {
                    try await access.create(at: path, from: Data("pdf".utf8), staging: staging)
                }
            }
            #expect(try sandbox.names() == ["other"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func removeStagingRemovesALeftoverAndIgnoresAMissingOne(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let staging = LeoFileName.stagingPath(for: sandbox.path("x.pdf"))
            try sandbox.file((staging as NSString).lastPathComponent, "partial")

            try await access.removeStaging(staging)
            try await access.removeStaging(staging)

            #expect(try sandbox.names().isEmpty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func removeStagingRefusesNonStagingNames(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let destination = try sandbox.file("x.pdf", "keep me")
            let lookalike = try sandbox.file(".x.pdf.leo-1234.tmp", "keep me too")

            for path in [destination, lookalike, "relative/.x.pdf.leo-\(String(repeating: "a", count: 32)).tmp"] {
                await #expect(throws: LeoFileAccessError.invalidPath(path)) { try await access.removeStaging(path) }
            }

            #expect(try sandbox.names() == [".x.pdf.leo-1234.tmp", "x.pdf"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func createStreamsAMultiChunkSourceExactly(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let payload = leoPatternData(count: 3 * kind.writeChunkSize + 1)
            let source = LeoRecordingByteSource(payload)

            let stat = try await access.create(at: sandbox.path("big.bin"), from: source)

            #expect(try Data(contentsOf: URL(fileURLWithPath: sandbox.path("big.bin"))) == payload)
            #expect(stat.size == UInt64(payload.count))
            #expect(source.requestedCounts.allSatisfy { $0 <= kind.writeChunkSize })
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func createsAnEmptyFileFromAnEmptySource(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try await access.create(at: sandbox.path("empty"), from: Data())
            #expect(try sandbox.contents("empty").isEmpty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func createsANewFileAndReturnsItsStat(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = sandbox.path("new.txt")

            let stat = try await access.write(Data("fresh".utf8), to: path, expecting: nil)

            #expect(try sandbox.contents("new.txt") == "fresh")
            #expect(stat.kind == .file)
            #expect(stat.version == (try await access.stat(path)).version)
            #expect(try sandbox.names() == ["new.txt"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func replacesByRenamingATempFileAndKeepsPermissions(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("f.sh", "old", permissions: 0o750)
            let originalInode = try sandbox.inode("f.sh")
            let version = try await access.read(path, maxBytes: 100).stat.version

            try await access.write(Data("new contents".utf8), to: path, expecting: version)

            #expect(try sandbox.contents("f.sh") == "new contents")
            #expect(try sandbox.permissions("f.sh") == 0o750)
            #expect(try sandbox.inode("f.sh") != originalInode, "an in-place rewrite would keep the inode")
            #expect(try sandbox.names() == ["f.sh"], "no temp file may be left behind")
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func keepsReadOnlyPermissionsToo(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("ro.txt", "old", permissions: 0o444)

            try await access.write(Data("new".utf8), to: path, expecting: nil)

            #expect(try sandbox.contents("ro.txt") == "new")
            #expect(try sandbox.permissions("ro.txt") == 0o444)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func consecutiveSavesChainTheReturnedVersion(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("f.txt", "v1")
            let first = try await access.read(path, maxBytes: 100).stat.version

            let second = try await access.write(Data("v2".utf8), to: path, expecting: first).version
            try await access.write(Data("v3".utf8), to: path, expecting: second)

            #expect(try sandbox.contents("f.txt") == "v3")
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func detectsAConflictWhenTheFileChangedSize(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("f.txt", "original")
            let version = try await access.read(path, maxBytes: 100).stat.version
            try sandbox.file("f.txt", "changed by an agent")

            await #expect(throws: LeoFileAccessError.conflict(path: path)) {
                try await access.write(Data("mine".utf8), to: path, expecting: version)
            }
            #expect(try sandbox.contents("f.txt") == "changed by an agent")
            #expect(try sandbox.names() == ["f.txt"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func detectsAConflictWhenOnlyTheModificationTimeChanged(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("f.txt", "same")
            let version = try await access.read(path, maxBytes: 100).stat.version
            try sandbox.file("f.txt", "SAME")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: path)

            await #expect(throws: LeoFileAccessError.conflict(path: path)) {
                try await access.write(Data("mine".utf8), to: path, expecting: version)
            }
            #expect(try sandbox.contents("f.txt") == "SAME")
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func detectsAConflictWhenTheFileWasDeleted(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("f.txt", "original")
            let version = try await access.read(path, maxBytes: 100).stat.version
            try FileManager.default.removeItem(atPath: path)

            await #expect(throws: LeoFileAccessError.conflict(path: path)) {
                try await access.write(Data("mine".utf8), to: path, expecting: version)
            }
            #expect(try sandbox.names().isEmpty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func writesThroughASymlinkToItsTarget(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try sandbox.file("AGENTS.md", "old", permissions: 0o600)
            let link = try sandbox.symlink("CLAUDE.md", to: "AGENTS.md")
            let version = try await access.read(link, maxBytes: 100).stat.version

            try await access.write(Data("new".utf8), to: link, expecting: version)

            #expect(try sandbox.contents("AGENTS.md") == "new")
            #expect(try sandbox.permissions("AGENTS.md") == 0o600)
            let linkType = try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType
            #expect(linkType == .typeSymbolicLink)
            #expect(try sandbox.names() == ["AGENTS.md", "CLAUDE.md"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func writingThroughADanglingSymlinkIsNotFound(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let link = try sandbox.symlink("dangling", to: "missing.txt")
            await #expect(throws: LeoFileAccessError.notFound(path: link)) {
                try await access.write(Data("x".utf8), to: link, expecting: nil)
            }
            #expect(try sandbox.names() == ["dangling"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func writingOverADirectoryIsADirectory(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let directory = try sandbox.directory("d")
            await #expect(throws: LeoFileAccessError.isADirectory(path: directory)) {
                try await access.write(Data("x".utf8), to: directory, expecting: nil)
            }
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func writingIntoAReadOnlyDirectoryIsPermissionDenied(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try sandbox.directory("locked")
            let path = try sandbox.file("locked/f.txt", "old")
            try sandbox.chmod("locked", 0o500)

            await #expect(throws: LeoFileAccessError.permissionDenied(path: path)) {
                try await access.write(Data("new".utf8), to: path, expecting: nil)
            }
            #expect(try sandbox.contents("locked/f.txt") == "old")
            #expect(try sandbox.names(in: "locked") == ["f.txt"])
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func roundTripsALargeFileAcrossChunkBoundaries(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = sandbox.path("large.bin")
            let payload = leoPatternData(count: 5 * 32 * 1024 + 123)

            try await access.write(payload, to: path, expecting: nil)
            let contents = try await access.read(path, maxBytes: 1 << 20)

            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == payload)
            #expect(contents.data == payload)
            #expect(contents.stat.size == UInt64(payload.count))
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func writesAnEmptyFile(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("f.txt", "something")
            try await access.write(Data(), to: path, expecting: nil)
            #expect(try sandbox.contents("f.txt").isEmpty)
            #expect(try await access.read(path, maxBytes: 10).data.isEmpty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func writesFilesWhoseNamesAreNearTheLengthLimit(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let name = String(repeating: "n", count: 250)
            let path = try sandbox.file(name, "old")

            try await access.write(Data("new".utf8), to: path, expecting: nil)

            #expect(try sandbox.contents(name) == "new")
            #expect(try sandbox.names() == [name])
        }
    }

    /// Opening a FIFO blocks until a writer appears -- locally that would
    /// hang the caller, remotely the whole sftp-server.
    @Test(arguments: LeoFileBackendKind.allCases)
    func specialFilesAreNeverOpened(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let fifo = sandbox.path("pipe")
            #expect(mkfifo(fifo, 0o644) == 0)
            let expected = LeoFileAccessError.failed(path: fifo, reason: "it isn’t a regular file")

            await #expect(throws: expected) { try await access.read(fifo, maxBytes: 10) }
            await #expect(throws: expected) { try await access.write(Data("x".utf8), to: fifo, expecting: nil) }
            let kinds = try await access.list(sandbox.root).map(\.kind)
            #expect(kinds == [.other])
        }
    }
}
