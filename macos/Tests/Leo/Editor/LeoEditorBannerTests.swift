import AppKit
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
            #expect(banner.message == "Quitting is waiting for localhost to finish with “\u{2068}a.txt\u{2069}”.")
            #expect(LeoEditorBanner.Action.quitAnyway.title == "Quit Anyway…")
            #expect(LeoEditorBanner.current(for: document)?.actions == [.reload, .keepMine])
            #expect(LeoEditorBanner.current(for: nil, isQuitWaiting: true) == nil)
        }
    }

    /// The pane shows it only once the close is actually waiting on the
    /// disk or connection -- never before or over its own prompt, so it
    /// doesn't flash ahead of each prompt -- and its button makes the offer.
    @Test(.timeLimit(.minutes(1)))
    func thePaneOffersToQuitAnywayOnlyOnceTheCloseIsWaiting() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            // The open's own access, which its cancel closes, apart from the document's.
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let reader = LeoHangingAccess(LeoFileAccessor.local())
            var accesses = [access, reader]
            let model = LeoEditorPaneModel(makeAccess: { _ in accesses.removeFirst() })
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

            // As the gate does, just before asking the editor to close.
            model.leaveAnyway = { offers += 1 }
            #expect(pane.shownBanner == nil, "not before its prompt")
            let closing = Task { await model.close() }
            for await _ in prompts { break }
            #expect(pane.shownBanner == nil, "not over its own prompt")

            access.hangsWrites = true
            answer.yield(.save)
            await access.waitUntilWriting()
            #expect(pane.shownBanner?.actions == [.quitAnyway], "the save isn't coming back")
            pane.perform(.quitAnyway)
            #expect(offers == 1)

            access.release()
            #expect(await closing.value)
            #expect(pane.shownBanner == nil)
        }
    }

    /// The banner view itself follows the gate: shown when a pending quit
    /// starts waiting on the editor, back to "Closing…" while no quit is
    /// pending, and hidden once the close is done.
    @Test(.timeLimit(.minutes(1)))
    func theBannerViewFollowsThePendingQuit() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let model = LeoEditorPaneModel(makeAccess: { _ in access })
            let pane = LeoEditorPaneViewController(model: model)
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            model.confirmUnsaved = { _ in .save }
            access.hangsWrites = true
            // As the gate does: set before the close, while nothing waits.
            model.leaveAnyway = {}
            await nextTurn()
            #expect(pane.banner.isHidden)

            let closing = Task { await model.close() }
            await access.waitUntilWriting()
            #expect(await eventually { !pane.banner.isHidden && pane.banner.banner?.actions == [.quitAnyway] })

            model.isOfferShowing = true
            #expect(await eventually { pane.banner.banner?.isEnabled == false }, "disabled while an offer is up")
            model.isOfferShowing = false
            #expect(await eventually { pane.banner.banner?.isEnabled == true })

            model.leaveAnyway = nil
            #expect(await eventually { pane.banner.banner?.actions == [] }, "still closing, with no quit to leave")
            model.leaveAnyway = {}
            #expect(await eventually { pane.banner.banner?.actions == [.quitAnyway] })

            access.release()
            #expect(await closing.value)
            #expect(await eventually { pane.banner.isHidden })
        }
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// After Don't Save, while the close waits on the document's in-flight
    /// work, the text is read-only: nothing typed then would be kept (or,
    /// worse, written by a save queued behind it).
    @Test(.timeLimit(.minutes(1)))
    func theTextIsReadOnlyWhileTheCloseWaits() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let model = LeoEditorPaneModel(makeAccess: { _ in access })
            let pane = LeoEditorPaneViewController(model: model)
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            await nextTurn()
            #expect(pane.textView.isEditable)
            model.confirmUnsaved = { _ in .discard }
            access.hangsWrites = true
            let commandS = Task { await model.document?.save() }
            await access.waitUntilWriting()

            let closing = Task { await model.close() }
            #expect(await eventually { model.isWaitingToClose })
            #expect(await eventually { !pane.textView.isEditable })

            access.release()
            _ = await commandS.value
            #expect(await closing.value)
        }
    }

    /// A close queued behind an operation that isn't coming back (a read
    /// that hangs) is waiting from the start.
    @Test(.timeLimit(.minutes(1)))
    func aCloseQueuedBehindAHungOperationIsWaiting() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let model = LeoEditorPaneModel(makeAccess: { _ in access })
            let pane = LeoEditorPaneViewController(model: model)
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            model.leaveAnyway = {}
            access.hangsReads = true
            let opening = Task { try? await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("b.txt", "b"))) }
            await access.waitUntilReading()

            let closing = Task { await model.close() }
            #expect(await eventually { pane.shownBanner?.actions == [.quitAnyway] })

            model.confirmUnsaved = { _ in .discard }
            access.release()
            _ = await opening.value
            #expect(await closing.value)
        }
    }

    /// A close waiting on the disk or connection with no quit behind it
    /// (a plain ⌘W) says so calmly, with nothing to press (B-024); a
    /// pending quit's offer to leave comes first.
    @Test func aCloseWaitingOnTheEditorSaysClosing() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let document = try await open(sandbox, "a.txt", "a")
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")
            await document.checkDisk()

            #expect(LeoEditorBanner.current(for: document, isWaitingToClose: true) == Self.closing)
            #expect(LeoEditorBanner.current(for: document, isQuitWaiting: true, isWaitingToClose: true)?.actions == [.quitAnyway])
            #expect(LeoEditorBanner.current(for: nil, isWaitingToClose: true) == nil)
        }
    }

    private static let closing = LeoEditorBanner(symbol: "hourglass", message: "Closing “\u{2068}a.txt\u{2069}”…", actions: [])

    /// A plain ⌘W behind a hung save: the text locks, and the pane says why.
    @Test(.timeLimit(.minutes(1)))
    func aPlainCloseBehindAHungSaveSaysClosing() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let model = LeoEditorPaneModel(makeAccess: { _ in access })
            let pane = LeoEditorPaneViewController(model: model)
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            model.confirmUnsaved = { _ in .save }
            access.hangsWrites = true

            let closing = Task { await model.close() }
            await access.waitUntilWriting()

            #expect(model.isWaitingToClose)
            #expect(await eventually { pane.banner.banner == Self.closing })
            #expect(!pane.banner.isHidden)
            #expect(!pane.textView.isEditable)
            access.release()
            #expect(await closing.value)
            #expect(await eventually { pane.banner.isHidden })
        }
    }

    /// A close queued behind a slow open is waiting, but nothing is decided
    /// yet: the text stays editable (it may still be kept) until the close's
    /// prompt is answered, and locks only then (B-024).
    @Test(.timeLimit(.minutes(1)))
    func aCloseQueuedBehindASlowOpenLocksTheTextOnlyOnceItsPromptIsAnswered() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            // The open's own access, which its cancel closes, apart from the document's.
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let reader = LeoHangingAccess(LeoFileAccessor.local())
            var accesses = [access, reader]
            let model = LeoEditorPaneModel(makeAccess: { _ in accesses.removeFirst() })
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
            reader.hangsReads = true
            let opening = Task { try? await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("b.txt", "b"))) }
            await reader.waitUntilReading()

            let closing = Task { await model.close() }
            #expect(await eventually { pane.banner.banner == Self.closing }, "waiting behind the open")
            #expect(pane.textView.isEditable, "not locked before its prompt")

            reader.release()
            for await _ in prompts { break }
            answer.yield(.cancel)
            #expect(await opening.value == .cancelled)
            for await _ in prompts { break }
            await nextTurn()
            #expect(pane.textView.isEditable, "not locked over its own prompt")

            access.hangsWrites = true
            answer.yield(.save)
            await access.waitUntilWriting()
            #expect(await eventually { !pane.textView.isEditable }, "locked once the prompt is answered")
            access.release()
            #expect(await closing.value)
        }
    }

    /// Overlapping closes: one cancelled at its prompt ends while the
    /// next, decided (Don't Save), still waits on a save in flight. The
    /// pane stays locked, and closing, until that one is done.
    @Test(.timeLimit(.minutes(1)))
    func aCloseThatEndsEarlyLeavesAnotherCloseLocked() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let model = LeoEditorPaneModel(makeAccess: { _ in access })
            let pane = LeoEditorPaneViewController(model: model)
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            var answers: [LeoUnsavedChangesChoice] = [.cancel, .discard]
            model.confirmUnsaved = { _ in answers.removeFirst() }
            access.hangsWrites = true
            let commandS = Task { await model.document?.save() }
            await access.waitUntilWriting()

            let first = Task { await model.close() }
            let second = Task { await model.close() }
            #expect(await first.value == false)
            #expect(await eventually { model.isCommittedToClose && !pane.textView.isEditable })
            await nextTurn()

            #expect(model.isCommittedToClose, "the first close ending doesn't unlock the second")
            #expect(model.isWaitingToClose)
            #expect(!pane.textView.isEditable)
            #expect(pane.banner.banner == Self.closing)
            access.release()
            _ = await commandS.value
            #expect(await second.value)
            #expect(!model.isCommittedToClose && !model.isWaitingToClose)
        }
    }

    /// Once a close is decided, the model refuses edits itself -- a
    /// keystroke that lands before the view's lock does isn't taken (the
    /// close would drop it) -- and the view puts the model's text back.
    @Test(.timeLimit(.minutes(1)))
    func aKeystrokeRacingTheLockIsRefusedAndUndone() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let model = LeoEditorPaneModel(makeAccess: { _ in access })
            let pane = LeoEditorPaneViewController(model: model)
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            model.document?.edit("b")
            await nextTurn()
            model.confirmUnsaved = { _ in .discard }
            access.hangsWrites = true
            let commandS = Task { await model.document?.save() }
            await access.waitUntilWriting()
            let closing = Task { await model.close() }
            #expect(await eventually { model.isCommittedToClose })

            #expect(!model.edit("typed", revision: model.document?.contentRevision ?? 0))
            #expect(model.document?.text == "b")
            pane.textView.string = "b, typed"
            pane.textDidChange(Notification(name: NSText.didChangeNotification, object: pane.textView))
            #expect(model.document?.text == "b", "not taken")
            #expect(pane.textView.string == "b", "put back")

            access.release()
            _ = await commandS.value
            #expect(await closing.value)
        }
    }

    /// Before any close is decided, edits go through the model as ever.
    @Test func editsGoThroughWhileNoCloseIsDecided() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let model = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            #expect(model.edit("b", revision: model.document?.contentRevision ?? 0))
            #expect(model.document?.text == "b")
            #expect(model.document?.isDirty == true)
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aChangedFileOffersReloadAndKeepMine() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let document = try await open(sandbox, "a.txt", "a")
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")
            await document.checkDisk()

            let banner = try #require(LeoEditorBanner.current(for: document))
            #expect(banner.actions == [.reload, .keepMine])
            #expect(banner.message.hasPrefix("“\u{2068}a.txt\u{2069}” changed on disk."))
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
