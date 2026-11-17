import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The workspace file picker over real backends, with a fake panel (no
/// window) and a fake Mac chooser: rooted at the workspace, files only,
/// chosen files copied to private local URLs under their own names, and
/// nothing left behind by a cancel or a closed browser.
@MainActor
@Suite(.hostOnly, .serialized)
struct LeoBrowserWorkspaceFilePickerTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp]

    // MARK: - Harness

    @MainActor private final class FakePresenter: LeoBrowserUploadPanelPresenting {
        private(set) var shown: [LeoBrowserWorkspacePick] = []
        private(set) var dismissed = 0

        func show(_ pick: LeoBrowserWorkspacePick) -> any LeoBrowserUploadPanelHandle {
            shown.append(pick)
            return Handle(presenter: self)
        }

        private struct Handle: LeoBrowserUploadPanelHandle {
            let presenter: FakePresenter
            func dismiss() { presenter.dismissed += 1 }
        }
    }

    @MainActor private final class FakeMacPicker: LeoBrowserFilePicking {
        private(set) var requests: [LeoBrowserFilePickRequest] = []
        private(set) var dismissed = 0
        private var completion: (@MainActor ([URL]?) -> Void)?

        func present(_ request: LeoBrowserFilePickRequest, completion: @escaping @MainActor ([URL]?) -> Void) -> any LeoBrowserFilePickSession {
            requests.append(request)
            self.completion = completion
            return Session(picker: self)
        }

        func answer(_ urls: [URL]?) { completion?(urls) }

        private struct Session: LeoBrowserFilePickSession {
            let picker: FakeMacPicker
            func dismiss() { picker.dismissed += 1 }
        }
    }

    @MainActor private final class Results {
        var answers: [[URL]?] = []
    }

    @MainActor private struct Harness {
        let picker: LeoBrowserWorkspaceFilePicker
        let presenter: FakePresenter
        let mac: FakeMacPicker
        let staging: URL
        let results = Results()

        @discardableResult
        func present(multiple: Bool = false, directories: Bool = false) -> any LeoBrowserFilePickSession {
            let request = LeoBrowserFilePickRequest(agent: "alpha", origin: "example.com", allowsMultipleSelection: multiple, allowsDirectories: directories)
            let results = results
            return picker.present(request) { results.answers.append($0) }
        }

        var pick: LeoBrowserWorkspacePick { presenter.shown.last! }

        func cleanUp() {
            picker.close()
            try? FileManager.default.removeItem(at: staging)
        }
    }

    private func harness(
        _ sandbox: LeoFileSandbox, workspace: String? = nil, makeAccess: @escaping @MainActor () -> any LeoFileAccess
    ) -> Harness {
        let presenter = FakePresenter()
        let mac = FakeMacPicker()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("leo-upload-picks-\(UUID().uuidString.prefix(8))")
        let root = workspace ?? sandbox.path("ws")
        let picker = LeoBrowserWorkspaceFilePicker(
            host: .local, agent: "alpha", workspace: { root }, makeAccess: { _ in makeAccess() },
            fallback: mac, presenter: presenter, stagingRoot: staging
        )
        return Harness(picker: picker, presenter: presenter, mac: mac, staging: staging)
    }

    private func workspace() throws -> LeoFileSandbox {
        let sandbox = try LeoFileSandbox()
        try sandbox.directory("ws/docs")
        try sandbox.file("ws/a.txt", "top")
        try sandbox.file("ws/docs/a.txt", "nested")
        try sandbox.file("outside.txt", "not yours")
        return sandbox
    }

    private func entry(_ pick: LeoBrowserWorkspacePick, _ name: String, in folder: String? = nil) throws -> LeoWorkspaceEntry {
        let items = folder.map(pick.model.items(in:)) ?? pick.model.rootItems
        for case let .entry(entry) in items where entry.name == name { return entry }
        Issue.record("no \(name) in \(folder ?? "the root")")
        throw CancellationError()
    }

    private func files(in folder: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.lastPathComponent)
    }

    // MARK: - Tests

    @Test(arguments: kinds)
    func listsWorkspaceRootNotItsParent(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let h = harness(sandbox) { kind.makeAccess() }
        defer { h.cleanUp() }

        h.present()
        await h.pick.waitUntilOpen()

        #expect(h.pick.model.root?.path == sandbox.path("ws"))
        let names = h.pick.model.rootItems.compactMap { item -> String? in if case let .entry(entry) = item { entry.name } else { nil } }
        #expect(names == ["docs", "a.txt"])
        #expect(h.pick.workspaceLabel == (sandbox.path("ws") as NSString).abbreviatingWithTildeInPath)
        #expect(h.mac.requests.isEmpty)
        h.pick.cancel()
    }

    @Test func foldersCannotBeChosen() async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let h = harness(sandbox) { LeoFileAccessor.local() }
        defer { h.cleanUp() }
        h.present(multiple: true)
        await h.pick.waitUntilOpen()

        h.pick.select([try entry(h.pick, "docs")])
        #expect(h.pick.selection.isEmpty)
        #expect(!h.pick.canChoose)
        h.pick.choose()
        await h.pick.waitForCopy()

        #expect(h.results.answers.isEmpty)
        h.pick.cancel()
    }

    @Test func singleInputKeepsOneSelection() async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        try sandbox.file("ws/b.txt", "b")
        let h = harness(sandbox) { LeoFileAccessor.local() }
        defer { h.cleanUp() }
        h.present(multiple: false)
        await h.pick.waitUntilOpen()
        let a = try entry(h.pick, "a.txt")
        let b = try entry(h.pick, "b.txt")

        h.pick.select([a, b])
        #expect(h.pick.selection == [b])

        h.pick.cancel()
        h.present(multiple: true)
        await h.pick.waitUntilOpen()
        h.pick.select([a, try entry(h.pick, "docs"), b])
        #expect(h.pick.selection == [a, b], "folders dropped, files kept")
        h.pick.cancel()
    }

    @Test(arguments: kinds)
    func chooseCopiesToLocalURLsWithOriginalNames(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let h = harness(sandbox) { kind.makeAccess() }
        defer { h.cleanUp() }
        h.present(multiple: true)
        await h.pick.waitUntilOpen()
        await h.pick.model.expand(sandbox.path("ws/docs"))

        h.pick.select([try entry(h.pick, "a.txt"), try entry(h.pick, "a.txt", in: sandbox.path("ws/docs"))])
        h.pick.choose()
        await h.pick.waitForCopy()

        let urls = try #require(h.results.answers.first ?? nil)
        #expect(urls.map(\.lastPathComponent) == ["a.txt", "a.txt"], "same names, kept")
        #expect(Set(urls).count == 2)
        #expect(try urls.map { try String(contentsOf: $0, encoding: .utf8) } == ["top", "nested"])
        #expect(urls.allSatisfy { $0.path.hasPrefix(h.picker.stagingFolder.path) })
        #expect(h.presenter.dismissed == 1)
        #expect(h.results.answers.count == 1)
    }

    @Test func chooseFromMacHandsRequestToFallback() async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let h = harness(sandbox) { LeoFileAccessor.local() }
        defer { h.cleanUp() }
        let session = h.present(multiple: true)
        await h.pick.waitUntilOpen()

        h.pick.chooseFromMac()

        #expect(h.presenter.dismissed == 1)
        #expect(h.mac.requests.map(\.allowsMultipleSelection) == [true])
        #expect(h.results.answers.isEmpty)
        let chosen = [URL(filePath: "/tmp/from-mac.txt")]
        h.mac.answer(chosen)
        #expect(h.results.answers == [chosen])
        session.dismiss()
        #expect(h.mac.dismissed == 1, "dismissing reaches the Mac chooser it handed over to")
    }

    @Test func directoryRequestGoesStraightToFallback() async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let h = harness(sandbox) { LeoFileAccessor.local() }
        defer { h.cleanUp() }

        h.present(directories: true)

        #expect(h.presenter.shown.isEmpty)
        #expect(h.mac.requests.map(\.allowsDirectories) == [true])
    }

    @Test(arguments: [nil, "", "relative/ws"] as [String?])
    func noWorkspaceGoesStraightToFallback(_ workspace: String?) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let presenter = FakePresenter()
        let mac = FakeMacPicker()
        let picker = LeoBrowserWorkspaceFilePicker(
            host: .local, agent: "alpha", workspace: { workspace }, makeAccess: { _ in LeoFileAccessor.local() },
            fallback: mac, presenter: presenter, stagingRoot: URL(filePath: sandbox.path("staging"))
        )

        _ = picker.present(LeoBrowserFilePickRequest(agent: "alpha", origin: "x", allowsMultipleSelection: false, allowsDirectories: false)) { _ in }

        #expect(presenter.shown.isEmpty)
        #expect(mac.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelDuringCopyLeavesNothing() async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let gate = LeoHeldReads()
        let h = harness(sandbox) { LeoHeldReadAccess(base: LeoFileAccessor.local(), gate: gate) }
        defer { h.cleanUp() }
        h.present()
        await h.pick.waitUntilOpen()
        h.pick.select([try entry(h.pick, "a.txt")])

        h.pick.choose()
        await gate.waitUntilHeld()
        #expect(h.pick.copyingName == "a.txt")
        h.pick.cancel()
        gate.release()
        await h.pick.waitForCopy()

        #expect(h.results.answers.count == 1)
        #expect(h.results.answers.first == .some(nil))
        #expect(files(in: h.picker.stagingFolder).isEmpty)
        #expect(h.pick.error == nil)
    }

    @Test func closeRemovesStagedFiles() async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let h = harness(sandbox) { LeoFileAccessor.local() }
        defer { h.cleanUp() }
        h.present()
        await h.pick.waitUntilOpen()
        h.pick.select([try entry(h.pick, "a.txt")])
        h.pick.choose()
        await h.pick.waitForCopy()
        #expect(files(in: h.picker.stagingFolder) == ["a.txt"])

        h.picker.close()

        #expect(!FileManager.default.fileExists(atPath: h.picker.stagingFolder.path))
    }

    @Test func aFailedCopyStaysInThePanelAndLeavesNothing() async throws {
        let sandbox = try workspace()
        defer { sandbox.cleanUp() }
        let h = harness(sandbox) { LeoFileAccessor.local() }
        defer { h.cleanUp() }
        h.present()
        await h.pick.waitUntilOpen()
        h.pick.select([try entry(h.pick, "a.txt")])
        try FileManager.default.removeItem(atPath: sandbox.path("ws/a.txt"))

        h.pick.choose()
        await h.pick.waitForCopy()

        #expect(h.results.answers.isEmpty)
        #expect(h.pick.error?.hasPrefix("Couldn’t copy “a.txt”") == true)
        #expect(h.presenter.dismissed == 0)
        #expect(files(in: h.picker.stagingFolder).isEmpty)
        h.pick.cancel()
    }

    @Test func sweepRemovesEarlierRunsCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leo-upload-sweep-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("old/0"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("old/0/x.txt"))

        LeoBrowserWorkspaceFilePicker.sweep(root)

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

/// Holds every streamed read until released, like a slow SFTP transfer.
final class LeoHeldReads: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>]? in
                isHeld = true
                let held = heldWaiters
                heldWaiters = []
                if isReleased { return held + [continuation] }
                waiters.append(continuation)
                return held
            }
            resume?.forEach { $0.resume() }
        }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if isHeld { return true }
                heldWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isReleased = true
            let waiting = waiters
            waiters = []
            return waiting
        }
        waiting.forEach { $0.resume() }
    }
}

/// `base`, with every streamed read held at `gate` before it starts.
struct LeoHeldReadAccess: LeoFileAccess {
    let base: any LeoFileAccess
    let gate: LeoHeldReads

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }

    func read(_ path: String, into sink: any LeoFileByteSink) async throws -> LeoFileStat {
        await gate.hold()
        return try await base.read(path, into: sink)
    }

    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    func close() async { await base.close() }
}
