import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The agent browser's download saver over every real backend: local and
/// SFTP save identically, never overwrite, and never leave a partial file.
@Suite(.hostOnly)
struct LeoBrowserDownloadSaverContractTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp, .sftpSmallChunks]

    @Test(arguments: kinds)
    func savesIntoDownloadsCreatingFolder(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let payload = leoPatternData(count: 3 * kind.writeChunkSize + 11)
        let saver = LeoBrowserDownloadSaver(makeAccess: { kind.makeAccess() })

        let saved = try await saver.save(payload, suggestedName: "x.pdf", workspace: sandbox.root)

        #expect(saved.path == sandbox.path("downloads/x.pdf"))
        #expect(saved.workspacePath == "downloads/x.pdf")
        #expect(saved.size == UInt64(payload.count))
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == payload)
        #expect(try sandbox.names(in: "downloads") == ["x.pdf"])
    }

    @Test(arguments: kinds)
    func clashGetsNumberedNameNeverOverwrites(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("downloads")
        try sandbox.file("downloads/x.pdf", "one")
        try sandbox.file("downloads/x 2.pdf", "two")
        let saver = LeoBrowserDownloadSaver(makeAccess: { kind.makeAccess() })

        let saved = try await saver.save(Data("three".utf8), suggestedName: "x.pdf", workspace: sandbox.root)

        #expect(saved.workspacePath == "downloads/x 3.pdf")
        #expect(try sandbox.contents("downloads/x.pdf") == "one")
        #expect(try sandbox.contents("downloads/x 2.pdf") == "two")
        #expect(try sandbox.contents("downloads/x 3.pdf") == "three")
        #expect(try sandbox.names(in: "downloads") == ["x 2.pdf", "x 3.pdf", "x.pdf"])
    }

    /// A page capture (B-406) at a nested path: each missing folder level is
    /// made and the file lands whole, the same locally and over SFTP.
    @MainActor @Test(arguments: kinds)
    func savesCaptureIntoNestedFolder(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let payload = leoPatternData(count: 2 * kind.writeChunkSize + 5)
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { kind.makeAccess() }), workspace: { sandbox.root })

        let saved = try await log.saveCapture(payload, kind: .pdf, path: "reports/q3/", defaultName: "Docs.pdf")

        #expect(saved.path == sandbox.path("reports/q3/Docs.pdf"))
        #expect(saved.workspacePath == "reports/q3/Docs.pdf")
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == payload)
        #expect(try sandbox.names(in: "reports/q3") == ["Docs.pdf"])
    }

    @MainActor @Test(arguments: kinds)
    func captureClashNeverOverwrites(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.file("page.png", "old")
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { kind.makeAccess() }), workspace: { sandbox.root })

        let saved = try await log.saveCapture(Data("new".utf8), kind: .png, path: sandbox.path("page.png"), defaultName: "x.png")

        #expect(saved.workspacePath == "page 2.png")
        #expect(try sandbox.contents("page.png") == "old")
        #expect(try sandbox.contents("page 2.png") == "new")
    }

    /// The connection dies mid-write: the save fails as a lost connection,
    /// nothing is at the target, and the next save -- on a fresh connection
    /// -- removes the leftover staging, so `downloads/` holds only the new file.
    @Test(.timeLimit(.minutes(1)))
    func lostConnectionLeavesNoPartialFile() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let relay = LeoSFTPWriteLossRelay(writesBeforeCut: 2)
        let launcher = LeoSequenceSFTPLauncher(first: relay, later: LeoSFTPTestServer.launcher())
        let saver = LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.sftp(launcher: launcher) })
        let payload = leoPatternData(count: 40 * LeoSFTPOptions().chunkSize)

        await #expect(throws: LeoBrowserDownloadSaveError.lostConnection) {
            try await saver.save(payload, suggestedName: "x.bin", workspace: sandbox.root)
        }

        #expect(relay.cut)
        #expect(!FileManager.default.fileExists(atPath: sandbox.path("downloads/x.bin")))
        let leftovers = try sandbox.names(in: "downloads")
        #expect(leftovers.count == 1)
        #expect(leftovers.allSatisfy(LeoFileName.isStagingName), "the uncertain staging is retained until the next save")

        let saved = try await saver.save(Data("fresh".utf8), suggestedName: "x.bin", workspace: sandbox.root)

        #expect(saved.workspacePath == "downloads/x.bin")
        #expect(try sandbox.contents("downloads/x.bin") == "fresh")
        #expect(try sandbox.names(in: "downloads") == ["x.bin"])
    }
}
