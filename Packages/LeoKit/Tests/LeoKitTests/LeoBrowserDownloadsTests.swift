import Foundation
import Testing

@testable import LeoKit

/// The browser download saver and log over the local backend; the SFTP
/// backends run the same saver in the app's `LeoBrowserDownloadSaverContractTests`.
struct LeoBrowserDownloadsTests {
    // MARK: - Names

    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../a", "_a"),
        ("a/b", "a_b"),
        ("a\\b", "a_b"),
        (".hidden", "hidden"),
        ("...", "download"),
        ("", "download"),
        ("   ", "download"),
        ("evil\u{202E}fdp.exe", "evil_fdp.exe"),
        ("line\nbreak.txt", "line_break.txt"),
    ])
    func unsafeSuggestedNamesAreSanitised(suggested: String, expected: String) {
        let name = LeoBrowserDownloadName.sanitized(suggested)
        #expect(name == expected)
        #expect(LeoFileName.isSafeComponent(name))
    }

    @Test func overLongNamesKeepTheirExtensionWithinTheLimit() {
        let name = LeoBrowserDownloadName.sanitized(String(repeating: "é", count: 300) + ".pdf")
        #expect(name.utf8.count <= LeoBrowserDownloadName.maximumBytes)
        #expect(name.hasSuffix("é.pdf"))
        #expect(LeoFileName.isSafeComponent(name))
    }

    // MARK: - Saver

    @Test func savesIntoDownloadsCreatingFolder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let saver = LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() })

        let saved = try await saver.save(Data("%PDF".utf8), suggestedName: "x.pdf", workspace: sandbox.root)

        #expect(saved.path == sandbox.root + "/downloads/x.pdf")
        #expect(saved.workspacePath == "downloads/x.pdf")
        #expect(saved.size == 4)
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == Data("%PDF".utf8))
        #expect(try sandbox.names("downloads") == ["x.pdf"])
    }

    @Test func clashGetsNumberedNameNeverOverwrites() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.file("downloads/x.pdf", "one")
        try sandbox.file("downloads/x 2.pdf", "two")
        let saver = LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() })

        let saved = try await saver.save(Data("three".utf8), suggestedName: "x.pdf", workspace: sandbox.root)

        #expect(saved.workspacePath == "downloads/x 3.pdf")
        #expect(try sandbox.contents("downloads/x.pdf") == "one")
        #expect(try sandbox.contents("downloads/x 2.pdf") == "two")
        #expect(try sandbox.contents("downloads/x 3.pdf") == "three")
    }

    @Test func givesUpAfterAHundredNumberedNames() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.file("downloads/x", "taken")
        for number in 2...LeoBrowserDownloadSaver.numberedNameLimit { try sandbox.file("downloads/x \(number)", "taken") }
        let saver = LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() })

        await #expect(throws: LeoBrowserDownloadSaveError.noFreeName("x")) {
            try await saver.save(Data("new".utf8), suggestedName: "x", workspace: sandbox.root)
        }
        #expect(try sandbox.names("downloads").count == LeoBrowserDownloadSaver.numberedNameLimit)
    }

    @Test(arguments: [nil, "", "relative/ws"])
    func noWorkspaceFailsPlainly(workspace: String?) async throws {
        let access = RecordingAccess()
        let saver = LeoBrowserDownloadSaver(makeAccess: { access })

        await #expect(throws: LeoBrowserDownloadSaveError.noWorkspace) {
            try await saver.save(Data("x".utf8), suggestedName: "x.pdf", workspace: workspace)
        }
        #expect(access.calls.isEmpty)
    }

    @Test func aMissingWorkspaceIsNotCreated() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let saver = LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() })

        await #expect(throws: LeoBrowserDownloadSaveError.self) {
            try await saver.save(Data("x".utf8), suggestedName: "x.pdf", workspace: sandbox.root + "/gone")
        }
        #expect(try sandbox.names("").isEmpty)
    }

    /// A save that loses its connection leaves its staging name behind; the
    /// next save, on a fresh connection, removes it before writing.
    @Test func aLostConnectionsStagingIsRemovedByTheNextSave() async throws {
        let first = RecordingAccess(createError: .disconnected)
        let second = RecordingAccess()
        let accesses = Accesses([first, second])
        let saver = LeoBrowserDownloadSaver(makeAccess: { accesses.next() })

        await #expect(throws: LeoBrowserDownloadSaveError.lostConnection) {
            try await saver.save(Data("x".utf8), suggestedName: "x.pdf", workspace: "/ws")
        }
        let staging = try #require(first.stagings.first)
        #expect(first.closed)

        _ = try await saver.save(Data("x".utf8), suggestedName: "x.pdf", workspace: "/ws")
        #expect(second.removedStagings == [staging])
        #expect(second.closed)
    }

    @Test func anIndeterminatePublishIsReportedAsUncertain() async throws {
        let access = RecordingAccess(createError: .indeterminate(path: "/ws/downloads/x.pdf"))
        let saver = LeoBrowserDownloadSaver(makeAccess: { access })

        await #expect(throws: LeoBrowserDownloadSaveError.uncertain) {
            try await saver.save(Data("x".utf8), suggestedName: "x.pdf", workspace: "/ws")
        }
    }

    @Test func savesIntoAGivenNestedFolderCreatingEachLevel() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let saver = LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() })

        let saved = try await saver.save(Data("png".utf8), suggestedName: "a.png", workspace: sandbox.root, folder: "shots/today")

        #expect(saved.path == sandbox.root + "/shots/today/a.png")
        #expect(saved.workspacePath == "shots/today/a.png")
        #expect(try sandbox.contents("shots/today/a.png") == "png")
    }

    @Test func savesIntoTheWorkspaceItselfForAnEmptyFolder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let saver = LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() })

        let saved = try await saver.save(Data("pdf".utf8), suggestedName: "a.pdf", workspace: sandbox.root, folder: "")

        #expect(saved.path == sandbox.root + "/a.pdf")
        #expect(saved.workspacePath == "a.pdf")
    }

    @Test(arguments: ["..", "a/../..", "/etc", "a//b", "./a"])
    func aFolderThatCouldLeaveTheWorkspaceIsRefused(folder: String) async throws {
        let access = RecordingAccess()
        let saver = LeoBrowserDownloadSaver(makeAccess: { access })

        await #expect(throws: LeoBrowserDownloadSaveError.self) {
            try await saver.save(Data("x".utf8), suggestedName: "x.pdf", workspace: "/ws", folder: folder)
        }
        #expect(!access.calls.contains { $0.hasPrefix("create") || $0.hasPrefix("mkdir") })
    }

    @Test func messagesNameTheFolderTheyAreAbout() {
        #expect(LeoBrowserDownloadSaveError.noFreeName("a.png").message(in: "shots") == "Too many files named “a.png” are already in shots/.")
        #expect(LeoBrowserDownloadSaveError.noFreeName("a.png").message(in: "") == "Too many files named “a.png” are already in the workspace.")
        #expect(LeoBrowserDownloadSaveError.uncertain.message(in: "shots/today").contains("check shots/today/ before"))
        #expect(LeoBrowserDownloadSaveError.noFreeName("x").message == "Too many files named “x” are already in downloads/.")
    }

    // MARK: - Captures

    @MainActor @Test func captureSavesIntoNestedFolderCreatingIt() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { sandbox.root })

        let saved = try await log.saveCapture(Data("%PDF".utf8), kind: .pdf, path: "reports/q3/", defaultName: "Docs.pdf")

        #expect(saved.workspacePath == "reports/q3/Docs.pdf")
        #expect(saved.path == sandbox.root + "/reports/q3/Docs.pdf")
        #expect(try sandbox.contents("reports/q3/Docs.pdf") == "%PDF")
        #expect(log.entries.isEmpty, "a capture is not a download")
    }

    @MainActor @Test func captureWithoutPathGoesToDownloadsUnderTheDefaultName() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { sandbox.root })

        let saved = try await log.saveCapture(Data("png".utf8), kind: .png, path: nil, defaultName: "Docs.png")

        #expect(saved.workspacePath == "downloads/Docs.png")
    }

    @MainActor @Test func captureAtAnAbsolutePathInsideTheWorkspace() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { sandbox.root })

        let saved = try await log.saveCapture(Data("png".utf8), kind: .png, path: sandbox.root + "/shots/a", defaultName: "Docs.png")

        #expect(saved.workspacePath == "shots/a.png")
    }

    @MainActor @Test func captureClashGetsNumberedNameNeverOverwrites() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.file("page.pdf", "old")
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { sandbox.root })

        let saved = try await log.saveCapture(Data("new".utf8), kind: .pdf, path: "page.pdf", defaultName: "x.pdf")

        #expect(saved.workspacePath == "page 2.pdf")
        #expect(saved.name == "page 2.pdf")
        #expect(try sandbox.contents("page.pdf") == "old")
        #expect(try sandbox.contents("page 2.pdf") == "new")
    }

    @MainActor @Test func captureWithoutWorkspaceFails() async throws {
        let access = RecordingAccess()
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { access }), workspace: { nil })

        await #expect(throws: LeoBrowserError(.saveFailed, LeoBrowserDownloadSaveError.noWorkspace.message + " Nothing was saved.")) {
            try await log.saveCapture(Data("x".utf8), kind: .pdf, path: nil, defaultName: "x.pdf")
        }
        #expect(access.calls.isEmpty)
    }

    @MainActor @Test func captureAtAnInvalidPathIsInvalidArgsAndTouchesNothing() async throws {
        let access = RecordingAccess()
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { access }), workspace: { "/ws" })

        for path in ["../x.pdf", "/elsewhere/x.pdf", "x.png"] {
            do {
                _ = try await log.saveCapture(Data("x".utf8), kind: .pdf, path: path, defaultName: "x.pdf")
                Issue.record("\(path) saved")
            } catch let error as LeoBrowserError {
                #expect(error.code == .invalidArgs, "\(path)")
            }
        }
        #expect(access.calls.isEmpty)
    }

    @MainActor @Test func aCaptureSaveFailureNamesItsFolder() async throws {
        let access = RecordingAccess(createError: .indeterminate(path: "/ws/shots/x.pdf"))
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { access }), workspace: { "/ws" })

        await #expect(throws: LeoBrowserError(.saveFailed, LeoBrowserDownloadSaveError.uncertain.message(in: "shots"))) {
            try await log.saveCapture(Data("x".utf8), kind: .pdf, path: "shots/", defaultName: "x.pdf")
        }
    }

    @MainActor @Test func downloadsStillLandInDownloadsFolder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { sandbox.root })
        _ = try await log.saveCapture(Data("png".utf8), kind: .png, path: "shots/", defaultName: "a.png")
        let id = log.begin(suggestedName: "b.txt", sourceURL: nil)

        await log.complete(id, file: URL(fileURLWithPath: try sandbox.file("tmp-b", "b")))

        #expect(try sandbox.contents("downloads/b.txt") == "b")
    }

    // MARK: - Log

    @MainActor @Test func theLogRecordsProgressSavingAndTheSavedPathNewestFirst() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { sandbox.root })
        var changes = 0
        let stop = log.observe { changes += 1 }
        defer { stop() }

        let first = log.begin(suggestedName: "a.txt", sourceURL: URL(string: "https://a.test/a.txt"))
        let second = log.begin(suggestedName: "../b.txt", sourceURL: nil)
        log.progress(first, receivedBytes: 5, expectedBytes: 10)

        #expect(log.entries.map(\.id) == [second, first])
        #expect(log.entries.map(\.name) == ["_b.txt", "a.txt"])
        #expect(log.entries[1].state == .downloading(receivedBytes: 5, expectedBytes: 10))

        let file = try sandbox.file("tmp-a", "hello")
        await log.complete(first, file: URL(fileURLWithPath: file))

        guard case .finished(let saved) = log.entries[1].state else { Issue.record("expected finished, got \(log.entries[1].state)"); return }
        #expect(saved.workspacePath == "downloads/a.txt")
        #expect(try sandbox.contents("downloads/a.txt") == "hello")
        #expect(!FileManager.default.fileExists(atPath: file), "the local temp file is removed")
        #expect(changes >= 4)
    }

    @MainActor @Test func aFailedSaveIsShownPlainlyAndStillRemovesTheTempFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { nil })
        let id = log.begin(suggestedName: "a.txt", sourceURL: nil)
        let file = try sandbox.file("tmp-a", "hello")

        await log.complete(id, file: URL(fileURLWithPath: file))

        #expect(log.entries.first?.state == .failed(LeoBrowserDownloadSaveError.noWorkspace.message + " Nothing was saved."))
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @MainActor @Test func aNetworkFailureIsRecordedWithNothingSaved() {
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { RecordingAccess() }), workspace: { "/ws" })
        let id = log.begin(suggestedName: "a.txt", sourceURL: nil)

        log.fail(id, reason: "The network connection was lost.")

        #expect(log.entries.first?.state == .failed("The download failed: The network connection was lost. Nothing was saved."))
    }

    @MainActor @Test func aLateProgressReportNeverRevertsAnEndedDownload() {
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { RecordingAccess() }), workspace: { "/ws" })
        let id = log.begin(suggestedName: "a.txt", sourceURL: nil)
        log.fail(id, reason: "gone")

        log.progress(id, receivedBytes: 9, expectedBytes: 10)

        #expect(log.entries.first?.state == .failed("The download failed: gone. Nothing was saved."))
    }

    /// The history cap drops ended downloads only: a slow one outlives any
    /// number of newer ones and is still saved and listed when it finishes.
    @MainActor @Test func aSlowDownloadIsNeverDroppedByNewerOnes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { sandbox.root })
        let slow = log.begin(suggestedName: "slow.txt", sourceURL: nil)
        for index in 0..<LeoBrowserDownloads.historyLimit {
            log.fail(log.begin(suggestedName: "f\(index)", sourceURL: nil), reason: "gone")
        }
        let file = try sandbox.file("tmp-slow", "slow")

        await log.complete(slow, file: URL(fileURLWithPath: file))

        #expect(try sandbox.contents("downloads/slow.txt") == "slow")
        guard case .finished(let saved)? = log.entries.first(where: { $0.id == slow })?.state else {
            Issue.record("the slow download is not listed as finished: \(log.entries.map(\.id))")
            return
        }
        #expect(saved.workspacePath == "downloads/slow.txt")
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @MainActor @Test func theLogKeepsTheNewestEntriesOnly() {
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { RecordingAccess() }), workspace: { "/ws" })
        let ids = (0..<(LeoBrowserDownloads.historyLimit + 5)).map { index in
            let id = log.begin(suggestedName: "f\(index)", sourceURL: nil)
            log.fail(id, reason: "gone")
            return id
        }

        #expect(log.entries.count == LeoBrowserDownloads.historyLimit)
        #expect(log.entries.first?.id == ids.last)
        log.progress(ids[0], receivedBytes: 1, expectedBytes: 2)
        #expect(log.entries.count == LeoBrowserDownloads.historyLimit, "an update to a dropped entry is ignored")
    }
}

// MARK: - Support

private struct Sandbox {
    let root: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-downloads-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath().path
    }

    @discardableResult
    func file(_ relative: String, _ contents: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func contents(_ relative: String) throws -> String {
        try String(contentsOfFile: (root as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    func names(_ relative: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Hands out each access in turn.
private final class Accesses: @unchecked Sendable {
    private var remaining: [RecordingAccess]
    private let lock = NSLock()

    init(_ accesses: [RecordingAccess]) {
        remaining = accesses
    }

    func next() -> RecordingAccess {
        lock.withLock { remaining.removeFirst() }
    }
}

/// An empty, existing workspace whose creates fail with `createError`.
private final class RecordingAccess: LeoFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let createError: LeoFileAccessError?
    private var recorded: [String] = []
    private var stagingPaths: [String] = []
    private var removed: [String] = []
    private var isClosed = false

    init(createError: LeoFileAccessError? = nil) {
        self.createError = createError
    }

    var calls: [String] { lock.withLock { recorded } }
    var stagings: [String] { lock.withLock { stagingPaths } }
    var removedStagings: [String] { lock.withLock { removed } }
    var closed: Bool { lock.withLock { isClosed } }

    private func record(_ call: String) { lock.withLock { recorded.append(call) } }

    func list(_ path: String) async throws -> [LeoFileEntry] {
        record("list \(path)")
        return []
    }

    func stat(_ path: String) async throws -> LeoFileStat {
        record("stat \(path)")
        return LeoFileStat(kind: .directory, size: 0, modified: Date(), permissions: 0o755)
    }

    func homeDirectory() async throws -> String { "/home" }

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        throw LeoFileAccessError.notFound(path: path)
    }

    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        throw LeoFileAccessError.notFound(path: path)
    }

    func ensureDirectory(_ path: String) async throws { record("mkdir \(path)") }

    func create(at path: String, from source: any LeoFileByteSource, staging: String) async throws -> LeoFileStat {
        record("create \(path)")
        lock.withLock { stagingPaths.append(staging) }
        if let createError { throw createError }
        return LeoFileStat(kind: .file, size: 1, modified: Date(), permissions: 0o600)
    }

    func removeStaging(_ path: String) async throws {
        lock.withLock { removed.append(path) }
    }

    func close() async { lock.withLock { isClosed = true } }
}
