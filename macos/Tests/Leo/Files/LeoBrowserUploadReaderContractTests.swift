import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The agent browser's upload reader over every real backend: local and
/// SFTP read workspace files identically, and a missing one fails the same.
@Suite(.hostOnly)
struct LeoBrowserUploadReaderContractTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp, .sftpSmallChunks]

    @Test(arguments: kinds)
    func readsWorkspaceFilesWithNamesAndBytes(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let payload = leoPatternData(count: 3 * kind.writeChunkSize + 11)
        try FileManager.default.createDirectory(atPath: sandbox.path("img"), withIntermediateDirectories: true)
        try payload.write(to: URL(fileURLWithPath: sandbox.path("img/face.png")))
        try sandbox.file("notes.txt", "hello")
        let root = sandbox.root
        let reader = LeoBrowserUploadReader(makeAccess: { kind.makeAccess() }, workspace: { root })

        let files = try await reader.read(["img/face.png", root + "/notes.txt"])

        #expect(files.map(\.name) == ["face.png", "notes.txt"])
        #expect(files.map(\.workspacePath) == ["img/face.png", "notes.txt"])
        #expect(files.map(\.mimeType) == ["image/png", "text/plain"])
        #expect(files.first?.data == payload)
        #expect(files.last?.data == Data("hello".utf8))
    }

    @Test(arguments: kinds)
    func missingPathIsNoSuchFile(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.file("notes.txt", "hello")
        let root = sandbox.root
        let reader = LeoBrowserUploadReader(makeAccess: { kind.makeAccess() }, workspace: { root })

        await #expect(throws: LeoBrowserError(.noSuchFile, "No file at docs/missing.pdf in the workspace")) {
            _ = try await reader.read(["notes.txt", "docs/missing.pdf"])
        }
    }
}
