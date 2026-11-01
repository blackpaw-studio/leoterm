import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// `mkdir -p` for `LeoFileAccess`, once per backend like the other contract
/// suites (so the SFTP MKDIR wire path runs against a real sftp-server).
@Suite(LeoSSHEndToEnd.trait)
struct LeoFileAccessEnsureDirectoryTests {
    private func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func createsMissingParentsPrivately(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try await access.ensureDirectory(sandbox.path("a/b/c"))

            for relative in ["a", "a/b", "a/b/c"] {
                var isDirectory: ObjCBool = false
                #expect(FileManager.default.fileExists(atPath: sandbox.path(relative), isDirectory: &isDirectory))
                #expect(isDirectory.boolValue)
                let mode = try permissions(sandbox.path(relative))
                #expect(mode == 0o700)
            }
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func leavesAnExistingDirectoryAndItsContentsAlone(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try sandbox.directory("keep")
            try sandbox.file("keep/note.txt", "mine", permissions: 0o644)
            try sandbox.chmod("keep", 0o755)

            try await access.ensureDirectory(sandbox.path("keep"))
            try await access.ensureDirectory(sandbox.path("keep"))

            let mode = try permissions(sandbox.path("keep"))
            #expect(try sandbox.contents("keep/note.txt") == "mine")
            #expect(mode == 0o755)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func aFileInTheWayFailsWithoutReplacingIt(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let file = try sandbox.file("blocker", "data")

            await #expect(throws: LeoFileAccessError.notADirectory(path: file)) {
                try await access.ensureDirectory(sandbox.path("blocker/inner"))
            }
            await #expect(throws: LeoFileAccessError.notADirectory(path: file)) {
                try await access.ensureDirectory(file)
            }
            #expect(try sandbox.contents("blocker") == "data")
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func rejectsRelativeAndDotDotPaths(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            await #expect(throws: LeoFileAccessError.invalidPath("relative/dir")) {
                try await access.ensureDirectory("relative/dir")
            }
            let escaping = sandbox.path("a/../b")
            await #expect(throws: LeoFileAccessError.invalidPath(escaping)) {
                try await access.ensureDirectory(escaping)
            }
            let names = try sandbox.names()
            #expect(names.isEmpty)
        }
    }
}
