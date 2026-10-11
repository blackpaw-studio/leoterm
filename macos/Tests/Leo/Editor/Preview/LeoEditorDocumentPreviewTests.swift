import Foundation
import Testing

@testable import Ghostty

/// Opening media, documents and binaries (B-278): fetched into the preview
/// cache (never through the 20 MB text read), refetched when the disk
/// changes, and cleaned up on every way out.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LeoEditorDocumentPreviewTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp, .sftpSmallChunks]

    private func withPreviews(
        _ kind: LeoFileBackendKind,
        _ body: (LeoFileSandbox, any LeoFileAccess, LeoFilePreviewCache) async throws -> Void
    ) async throws {
        let temp = try LeoFileSandbox()
        defer { temp.cleanUp() }
        let cache = LeoFilePreviewCache(root: URL(fileURLWithPath: temp.path("previews")))
        try await withLeoFileSandbox(kind) { workspace, access in
            try await body(workspace, access, cache)
        }
    }

    private func open(
        _ path: String, _ access: any LeoFileAccess, _ cache: LeoFilePreviewCache, policy: LeoEditorContentPolicy = .default
    ) async throws -> LeoEditorDocument {
        try await LeoEditorDocument.open(LeoEditorFileID(host: .local, path: path), access: access, policy: policy, cache: cache)
    }

    private func readyURL(_ document: LeoEditorDocument) async throws -> URL {
        await document.settlePreview()
        guard case .ready(let url) = document.preview?.state else {
            Issue.record("not ready: \(String(describing: document.preview?.state))")
            throw CancellationError()
        }
        return url
    }

    private func entries(_ cache: LeoFilePreviewCache) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: cache.root.path)) ?? []
    }

    @Test(arguments: kinds)
    func imageOpensAsPreview(_ kind: LeoFileBackendKind) async throws {
        try await withPreviews(kind) { workspace, access, cache in
            let payload = leoPatternData(count: 50_000)
            let path = workspace.path("shot.png")
            try payload.write(to: URL(fileURLWithPath: path))

            let document = try await open(path, access, cache)

            #expect(document.isPreview)
            #expect(document.isReadOnly)
            #expect(document.kind == .image)
            #expect(try Data(contentsOf: try await readyURL(document)) == payload)
            document.edit("x")
            #expect(!document.isDirty)
            #expect(await document.save() == .readOnly)
            await document.close()
        }
    }

    @Test(arguments: kinds)
    func movieBypassesTextCap(_ kind: LeoFileBackendKind) async throws {
        try await withPreviews(kind) { workspace, access, cache in
            let payload = leoPatternData(count: 4096)
            let path = workspace.path("clip.mp4")
            try payload.write(to: URL(fileURLWithPath: path))

            let document = try await open(path, access, cache, policy: LeoEditorContentPolicy(editableLimit: 512, readLimit: 1024))

            #expect(try Data(contentsOf: try await readyURL(document)) == payload)
            await document.close()
        }
    }

    @Test func aFolderNamedLikeAnImageStillFails() async throws {
        try await withPreviews(.local) { workspace, access, cache in
            let folder = try workspace.directory("pics.png")
            await #expect(throws: LeoFileAccessError.isADirectory(path: folder)) { try await open(folder, access, cache) }
            #expect(entries(cache).isEmpty)
        }
    }

    @Test func binarySniffIsUnsupportedNotText() async throws {
        try await withPreviews(.local) { workspace, access, cache in
            let path = workspace.path("blob.bin")
            try Data([0x7F, 0x45, 0x00, 0x01]).write(to: URL(fileURLWithPath: path))

            let document = try await open(path, access, cache)

            #expect(document.text.isEmpty)
            #expect(document.isPreview)
            #expect(document.preview?.state == .unsupported(typeName: LeoFilePreviewKind.typeName(forPath: path)))
            #expect(await document.save() == .readOnly)
        }
    }

    @Test func markdownStaysEditable() async throws {
        try await withPreviews(.local) { workspace, access, cache in
            let path = try workspace.file("README.md", "# Hi\n")

            let document = try await open(path, access, cache)
            document.edit("# Hi there\n")

            #expect(!document.isPreview)
            #expect(document.kind == .rendered(.markdown))
            #expect(await document.save() == .saved)
            #expect(try workspace.contents("README.md") == "# Hi there\n")
        }
    }

    @Test(arguments: kinds)
    func checkDiskRefetchesChangedPreview(_ kind: LeoFileBackendKind) async throws {
        try await withPreviews(kind) { workspace, access, cache in
            let path = try workspace.file("doc.pdf", "one")
            let document = try await open(path, access, cache)
            let first = try await readyURL(document)

            try workspace.file("doc.pdf", "second")
            #expect(await document.checkDisk() == .reloaded)
            let second = try await readyURL(document)

            #expect(try String(contentsOf: second, encoding: .utf8) == "second")
            #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
            #expect(await document.checkDisk() == .unchanged)
            await document.close()
            #expect(entries(cache).isEmpty)
        }
    }

    /// macOS clears $TMPDIR files left untouched: a preview whose cached
    /// file went is fetched again on the next disk check.
    @Test func aMissingCacheFileRefetches() async throws {
        try await withPreviews(.local) { workspace, access, cache in
            let path = try workspace.file("a.png", "png")
            let document = try await open(path, access, cache)
            let first = try await readyURL(document)
            try FileManager.default.removeItem(at: first.deletingLastPathComponent())

            #expect(await document.checkDisk() == .reloaded)
            let second = try await readyURL(document)

            #expect(try String(contentsOf: second, encoding: .utf8) == "png")
            #expect(await document.checkDisk() == .unchanged)
            await document.close()
        }
    }

    /// A first fetch cut off by the surfaced-open deadline closed the
    /// access for good: Try Again can't work, so it isn't offered.
    @Test func aTimedOutFetchOffersNoRetry() async throws {
        try await withPreviews(.local) { _, _, cache in
            let path = "/w/a.mov"
            let access = LeoReadDeadline(seconds: 5, sleep: { _ in }).wrap(HangingAccess(hanging: [path]))
            let document = try await open(path, access, cache)

            await document.settlePreview()

            guard case .failed(_, let canRetry) = document.preview?.state else {
                Issue.record("not failed: \(String(describing: document.preview?.state))")
                return
            }
            #expect(!canRetry)
            #expect(entries(cache).isEmpty)
            await document.close()
        }
    }

    @Test func anOrdinaryFailureOffersRetry() async throws {
        try await withPreviews(.local) { workspace, access, cache in
            let path = try workspace.file("a.mov", "movie")
            try workspace.chmod("a.mov", 0o000)
            let document = try await open(path, access, cache)

            await document.settlePreview()

            guard case .failed(_, let canRetry) = document.preview?.state else {
                Issue.record("not failed: \(String(describing: document.preview?.state))")
                return
            }
            #expect(canRetry)
            await document.close()
        }
    }

    @Test func aDeletedPreviewIsBanneredWithoutKeepMine() async throws {
        try await withPreviews(.local) { workspace, access, cache in
            let path = try workspace.file("a.png", "png")
            let document = try await open(path, access, cache)
            _ = try await readyURL(document)

            try FileManager.default.removeItem(atPath: path)

            #expect(await document.checkDisk() == .deleted)
            document.keepMine()
            #expect(document.diskState == .deleted)
            #expect(!document.isDirty)
            await document.close()
        }
    }

    @Test func closeDuringFetchCleansUp() async throws {
        let temp = try LeoFileSandbox()
        defer { temp.cleanUp() }
        let cache = LeoFilePreviewCache(root: URL(fileURLWithPath: temp.path("previews")))
        let path = try temp.file("big.mov", "movie")
        let gates = LeoGatedReads([], streams: [path])
        let access = gates.makeAccess(.local)
        let document = try await LeoEditorDocument.open(LeoEditorFileID(host: .local, path: path), access: access, policy: .default, cache: cache)
        await gates.waitUntil(.stream, path)
        #expect(document.preview?.state == .loading(fraction: nil))

        let closing = Task { await document.close() }
        gates.release(.stream, path)
        await closing.value

        #expect(entries(cache).isEmpty)
        #expect(document.preview?.state == .closed)
        await #expect(throws: LeoFileAccessError.closed) { try await access.stat(path) }
    }
}
