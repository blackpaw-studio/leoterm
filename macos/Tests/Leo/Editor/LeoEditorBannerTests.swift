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

    /// A pending quit waiting on this editor's disk or connection says so
    /// first, with the way out (B-022, D-038) -- above even a conflict.
    @Test func aQuitWaitingOnTheEditorOffersToQuitAnyway() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let document = try await open(sandbox, "a.txt", "a")
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")
            await document.checkDisk()

            let banner = try #require(LeoEditorBanner.current(for: document, isQuitWaiting: true))
            #expect(banner.actions == [.quitAnyway])
            #expect(banner.message == "Quitting is waiting for localhost to finish with “a.txt”.")
            #expect(LeoEditorBanner.Action.quitAnyway.title == "Quit Anyway…")
            #expect(LeoEditorBanner.current(for: document)?.actions == [.reload, .keepMine])
            #expect(LeoEditorBanner.current(for: nil, isQuitWaiting: true) == nil)
        }
    }

    /// The pane shows it while the quit waits on the disk, not while its
    /// own prompt is up, and its button makes the offer.
    @Test(.timeLimit(.minutes(1)))
    func thePaneOffersToQuitAnywayOutsideItsPrompt() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let model = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            let pane = LeoEditorPaneViewController(model: model)
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            let (answers, answer) = AsyncStream<LeoUnsavedChangesChoice>.makeStream()
            let (prompts, prompted) = AsyncStream<Void>.makeStream()
            model.confirmUnsaved = { _ in
                prompted.yield()
                for await choice in answers { return choice }
                return .cancel
            }
            var offers = 0
            #expect(pane.shownBanner == nil)

            model.leaveAnyway = { offers += 1 }
            #expect(pane.shownBanner?.actions == [.quitAnyway])
            pane.perform(.quitAnyway)
            #expect(offers == 1)

            let closing = Task { await model.close() }
            for await _ in prompts { break }
            #expect(pane.shownBanner == nil, "not over its own prompt")
            answer.yield(.discard)
            #expect(await closing.value)
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
