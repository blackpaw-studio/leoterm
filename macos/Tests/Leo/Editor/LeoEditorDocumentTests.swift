import Foundation
import Testing

@testable import Ghostty

/// The editor's document model against every file-access backend: dirty
/// tracking, save, and the external-change state machine (clean reload,
/// dirty banner, Keep Mine, deleted). Every external change alters the
/// file's size, since SFTP v3 mtimes are whole seconds.
@MainActor
@Suite(LeoSSHEndToEnd.trait)
struct LeoEditorDocumentTests {
    private func open(
        _ path: String,
        _ access: any LeoFileAccess,
        policy: LeoEditorContentPolicy = .default
    ) async throws -> LeoEditorDocument {
        try await LeoEditorDocument.open(LeoEditorFileID(host: .local, path: path), access: access, policy: policy)
    }

    // MARK: Opening and dirty tracking

    @Test(arguments: LeoFileBackendKind.allCases)
    func opensCleanWithTheFilesText(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("main.swift", "let x = 1\n")

            let document = try await open(path, access)

            #expect(document.text == "let x = 1\n")
            #expect(!document.isDirty)
            #expect(document.diskState == .inSync)
            #expect(document.readOnlyReason == nil)
            #expect(document.displayName == "main.swift")
            #expect(document.language == .swift)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func editingMarksDirtyAndEditingBackClearsIt(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "hello"), access)

            document.edit("hello!")
            #expect(document.isDirty)
            document.edit("hello")
            #expect(!document.isDirty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func openingAFolderOrMissingFileFails(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let folder = try sandbox.directory("d")
            await #expect(throws: LeoFileAccessError.isADirectory(path: folder)) { try await open(folder, access) }
            let missing = sandbox.path("nope.txt")
            await #expect(throws: LeoFileAccessError.notFound(path: missing)) { try await open(missing, access) }
        }
    }

    // MARK: Saving

    @Test(arguments: LeoFileBackendKind.allCases)
    func saveWritesTheBufferAndClearsDirty(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            document.edit("one two")

            #expect(await document.save() == .saved)

            #expect(try sandbox.contents("a.txt") == "one two")
            #expect(!document.isDirty)
            // The new version is the base: a focus check finds nothing.
            #expect(await document.checkDisk() == .unchanged)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func savingACleanBufferTouchesNothing(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            let inode = try sandbox.inode("a.txt")

            #expect(await document.save() == .unchanged)
            #expect(try sandbox.inode("a.txt") == inode)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func aFailedSaveShowsTheBackendsMessageAndStaysDirty(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            try sandbox.directory("locked")
            let path = try sandbox.file("locked/a.txt", "one")
            let document = try await open(path, access)
            try sandbox.chmod("locked", 0o555)
            document.edit("two")

            let expected = LeoFileAccessError.permissionDenied(path: path).localizedDescription
            #expect(await document.save() == .failed(expected))
            #expect(document.errorMessage == expected)
            #expect(document.isDirty)
            #expect(try sandbox.contents("locked/a.txt") == "one")

            document.dismissError()
            #expect(document.errorMessage == nil)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func readOnlyDocumentsNeverSave(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("big.txt", "0123456789ab")
            let document = try await open(path, access, policy: LeoEditorContentPolicy(editableLimit: 10, readLimit: 100))

            #expect(document.readOnlyReason == .tooLarge(size: 12, limit: 10))
            document.edit("changed")
            #expect(await document.save() == .readOnly)
            #expect(try sandbox.contents("big.txt") == "0123456789ab")
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func binaryFilesOpenReadOnly(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = sandbox.path("blob.bin")
            try Data([0x7F, 0x45, 0x00, 0x01]).write(to: URL(fileURLWithPath: path))

            #expect(try await open(path, access).readOnlyReason == .binary)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func filesOverTheReadLimitDontOpen(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("huge.txt", String(repeating: "x", count: 30))
            await #expect(throws: LeoFileAccessError.tooLarge(path: path, size: 30, limit: 20)) {
                try await open(path, access, policy: LeoEditorContentPolicy(editableLimit: 10, readLimit: 20))
            }
        }
    }

    // MARK: External changes

    @Test(arguments: LeoFileBackendKind.allCases)
    func aCleanBufferReloadsSilently(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            let revision = document.contentRevision
            try sandbox.file("a.txt", "one, then two")

            #expect(await document.checkDisk() == .reloaded)

            #expect(document.text == "one, then two")
            #expect(!document.isDirty)
            #expect(document.diskState == .inSync)
            #expect(document.contentRevision == revision + 1)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func aDirtyBufferShowsTheChangedBannerAndKeepsMine(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")

            #expect(await document.checkDisk() == .conflict)

            #expect(document.diskState == .changed)
            #expect(document.text == "mine")
            #expect(document.isDirty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func saveOverAConflictNeedsKeepMineFirst(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")
            await document.checkDisk()

            #expect(await document.save() == .needsResolution)
            #expect(try sandbox.contents("a.txt") == "theirs, longer")

            document.keepMine()
            #expect(document.diskState == .inSync)
            #expect(document.isDirty)
            #expect(await document.save() == .saved)
            #expect(try sandbox.contents("a.txt") == "mine")
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func keepMineStillCatchesALaterChange(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")
            await document.checkDisk()
            document.keepMine()
            try sandbox.file("a.txt", "theirs again, even longer")

            #expect(await document.checkDisk() == .conflict)
            #expect(document.diskState == .changed)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func saveCatchesAChangeTheFocusCheckMissed(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")

            #expect(await document.save() == .conflict)

            #expect(document.diskState == .changed)
            #expect(try sandbox.contents("a.txt") == "theirs, longer")
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func reloadTakesTheirsAndClearsTheBanner(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            document.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")
            await document.checkDisk()

            await document.reload()

            #expect(document.text == "theirs, longer")
            #expect(!document.isDirty)
            #expect(document.diskState == .inSync)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func aDeletedFileShowsItsBannerCleanOrDirty(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let clean = try await open(try sandbox.file("clean.txt", "one"), access)
            let dirty = try await open(try sandbox.file("dirty.txt", "one"), access)
            dirty.edit("mine")
            try FileManager.default.removeItem(atPath: sandbox.path("clean.txt"))
            try FileManager.default.removeItem(atPath: sandbox.path("dirty.txt"))

            #expect(await clean.checkDisk() == .deleted)
            #expect(await dirty.checkDisk() == .deleted)

            #expect(clean.diskState == .deleted)
            #expect(dirty.diskState == .deleted)
            #expect(clean.text == "one")
            #expect(await dirty.save() == .needsResolution)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func keepMineOnADeletedFileRecreatesItOnSave(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            try FileManager.default.removeItem(atPath: sandbox.path("a.txt"))
            await document.checkDisk()

            document.keepMine()

            #expect(document.isDirty)
            #expect(await document.save() == .saved)
            #expect(try sandbox.contents("a.txt") == "one")
            #expect(!document.isDirty)
        }
    }

    @Test(arguments: LeoFileBackendKind.allCases)
    func aFileRestoredAfterDeletionReloadsACleanBuffer(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            try FileManager.default.removeItem(atPath: sandbox.path("a.txt"))
            await document.checkDisk()
            try sandbox.file("a.txt", "restored")

            #expect(await document.checkDisk() == .reloaded)
            #expect(document.diskState == .inSync)
            #expect(document.text == "restored")
        }
    }

    /// A silent reload lands in the view a run-loop turn later; a
    /// keystroke in that gap was typed into the old text, so it must not
    /// mark the buffer dirty with it (⌘S would write the stale text back).
    @Test func anEditOfTheTextBeforeAReloadIsIgnored() async throws {
        try await withLeoFileSandbox(.local) { sandbox, access in
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            let shown = document.contentRevision
            try sandbox.file("a.txt", "one, then two")
            #expect(await document.checkDisk() == .reloaded)

            document.edit("one!", revision: shown)

            #expect(document.text == "one, then two")
            #expect(!document.isDirty)
            #expect(await document.save() == .unchanged)
            #expect(try sandbox.contents("a.txt") == "one, then two")
            // Once the view shows the reload, its edits count again.
            document.edit("one, then two!", revision: document.contentRevision)
            #expect(document.isDirty)
        }
    }

    /// A focus check that finds a change but can't read it hasn't reloaded.
    @Test func aCheckWhoseReloadFailsReportsFailure() async throws {
        try await withLeoFileSandbox(.local) { sandbox, local in
            let access = LeoFailingReadAccess(local)
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            let revision = document.contentRevision
            try sandbox.file("a.txt", "one, then two")
            access.failsReads = true

            #expect(await document.checkDisk() == .failed)

            #expect(document.text == "one")
            #expect(document.contentRevision == revision)
            #expect(!document.isDirty)
        }
    }

    /// Decoding (up to `readLimit`, 20 MB) runs off the main actor, on open
    /// and on reload.
    @Test func decodingRunsOffTheMainActor() async throws {
        try await withLeoFileSandbox(.local) { sandbox, access in
            let probe = LeoThreadProbe()
            let policy = LeoEditorContentPolicy.default
            let fileID = LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "one"))
            let document = try await LeoEditorDocument.open(fileID, access: access, policy: policy) { data in
                probe.record()
                return policy.evaluate(data)
            }
            try sandbox.file("a.txt", "one, then two")
            await document.reload()

            #expect(probe.calls == 2)
            #expect(probe.onMainThread == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func editsMadeWhileASaveIsInFlightStayDirty() async throws {
        try await withLeoFileSandbox(.local) { sandbox, local in
            let access = LeoGatedWriteAccess(local)
            let document = try await open(try sandbox.file("a.txt", "one"), access)
            document.edit("two")

            let save = Task { await document.save() }
            await access.waitUntilWriting()
            document.edit("three")
            access.release()

            #expect(await save.value == .saved)
            #expect(try sandbox.contents("a.txt") == "two")
            #expect(document.isDirty)
        }
    }
}

/// `base`, except `write` waits for `release()` (after signalling
/// `waitUntilWriting()`), so a test can act while a save is in flight.
private final class LeoGatedWriteAccess: LeoFileAccess, @unchecked Sendable {
    private let base: any LeoFileAccess
    private let writing = AsyncStream<Void>.makeStream()
    private let gate = AsyncStream<Void>.makeStream()

    init(_ base: any LeoFileAccess) {
        self.base = base
    }

    func waitUntilWriting() async {
        for await _ in writing.stream { return }
    }

    func release() {
        gate.continuation.yield()
    }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func close() async { await base.close() }

    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        writing.continuation.yield()
        for await _ in gate.stream { break }
        return try await base.write(data, to: path, expecting: expected)
    }
}

/// `base`, except `read` throws while `failsReads` is set.
private final class LeoFailingReadAccess: LeoFileAccess, @unchecked Sendable {
    private let base: any LeoFileAccess
    private let lock = NSLock()
    private var failing = false

    var failsReads: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    init(_ base: any LeoFileAccess) {
        self.base = base
    }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func close() async { await base.close() }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        if failsReads { throw LeoFileAccessError.unavailable(reason: "read failed") }
        return try await base.read(path, maxBytes: maxBytes)
    }
}

/// Counts calls, and how many were on the main thread.
private final class LeoThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (calls: 0, onMain: 0)

    var calls: Int { lock.withLock { counts.calls } }
    var onMainThread: Int { lock.withLock { counts.onMain } }

    func record() {
        let isMain = Thread.isMainThread
        lock.withLock {
            counts.calls += 1
            if isMain { counts.onMain += 1 }
        }
    }
}
