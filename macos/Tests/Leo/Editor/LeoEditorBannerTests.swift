import Foundation
import Testing

@testable import Ghostty

/// Which inline banner the pane shows: a disk conflict first, then a
/// failed save, then the read-only notice.
@MainActor
struct LeoEditorBannerTests {
    private func open(_ sandbox: LeoFileSandbox, _ name: String, _ contents: String) async throws -> LeoEditorDocument {
        let path = try sandbox.file(name, contents)
        return try await LeoEditorDocument.open(LeoEditorFileID(host: .local, path: path), access: LeoFileAccessor.local(), policy: .default)
    }

    @Test func aCleanDocumentInSyncHasNoBanner() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let document = try await open(sandbox, "a.txt", "a")
            #expect(LeoEditorBanner.current(for: document) == nil)
            #expect(LeoEditorBanner.current(for: nil) == nil)
        }
    }

    @Test func aChangedFileOffersReloadAndKeepMine() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let document = try await open(sandbox, "a.txt", "a")
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")
            await document.checkDisk()

            let banner = try #require(LeoEditorBanner.current(for: document))
            #expect(banner.actions == [.reload, .keepMine])
            #expect(banner.message.hasPrefix("“a.txt” changed on disk."))
        }
    }

    @Test func aDeletedFileOffersKeepMineOnly() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let document = try await open(sandbox, "a.txt", "a")
            try FileManager.default.removeItem(atPath: sandbox.path("a.txt"))
            await document.checkDisk()

            #expect(LeoEditorBanner.current(for: document)?.actions == [.keepMine])
        }
    }

    @Test func aFailedSaveShowsItsMessageUntilDismissed() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            try sandbox.directory("locked")
            let path = try sandbox.file("locked/a.txt", "a")
            let document = try await LeoEditorDocument.open(
                LeoEditorFileID(host: .local, path: path), access: LeoFileAccessor.local(), policy: .default
            )
            try sandbox.chmod("locked", 0o555)
            document.edit("b")
            await document.save()

            let banner = try #require(LeoEditorBanner.current(for: document))
            #expect(banner.message == LeoFileAccessError.permissionDenied(path: path).localizedDescription)
            #expect(banner.actions == [.dismissError])
            document.dismissError()
            #expect(LeoEditorBanner.current(for: document) == nil)
        }
    }

    @Test func aReadOnlyFileShowsItsNotice() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = sandbox.path("blob.bin")
            try Data([0x00, 0x01]).write(to: URL(fileURLWithPath: path))
            let document = try await LeoEditorDocument.open(
                LeoEditorFileID(host: .local, path: path), access: LeoFileAccessor.local(), policy: .default
            )

            #expect(LeoEditorBanner.current(for: document) == LeoEditorBanner(
                symbol: "lock", message: LeoEditorReadOnlyReason.binary.notice, actions: []
            ))
        }
    }
}
