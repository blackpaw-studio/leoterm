import AppKit
import Testing

@testable import Ghostty

/// Dragging files out of the workspace browser to Finder (B-279): each file
/// row offers a file promise that downloads on drop, through the same
/// `LeoFileAccess` for local and SFTP hosts. The header spinner shows while
/// a download runs; a failure shows in the footer and goes back to Finder.
@MainActor
struct LeoWorkspaceBrowserDragOutTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp]

    @MainActor private struct Harness {
        let model: LeoWorkspaceBrowserModel
        let browser: LeoWorkspaceBrowserViewController
        let window: NSWindow

        var outline: LeoWorkspaceOutlineView { browser.outlineView }

        func row(_ title: String) throws -> Int {
            try #require((0..<outline.numberOfRows).first { browser.title(ofRow: $0) == title })
        }

        func item(_ title: String) throws -> Any {
            try #require(outline.item(atRow: try row(title)))
        }

        func promise(_ title: String) throws -> LeoWorkspaceFilePromise {
            try #require(browser.outlineView(outline, pasteboardWriterForItem: try item(title)) as? LeoWorkspaceFilePromise)
        }

        func tearDown() async {
            window.close()
            await model.close()
        }
    }

    @MainActor private final class AccessQueue {
        private var accesses: [any LeoFileAccess]

        init(_ accesses: [any LeoFileAccess]) {
            self.accesses = accesses
        }

        func next() -> (any LeoFileAccess)? {
            accesses.isEmpty ? nil : accesses.removeFirst()
        }
    }

    /// `accesses` is handed out one per root, in order; when it runs out,
    /// `kind` makes the rest.
    private func makeHarness(_ kind: LeoFileBackendKind, root: String, accesses: [any LeoFileAccess] = []) async -> Harness {
        let queue = AccessQueue(accesses)
        let model = LeoWorkspaceBrowserModel(
            makeAccess: { _ in queue.next() ?? kind.makeAccess() },
            openFile: { _ in .opened }
        )
        let browser = LeoWorkspaceBrowserViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        await model.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: root))
        browser.sync()
        return Harness(model: model, browser: browser, window: window)
    }

    /// Calls the promise's delegate as AppKit does on a drop, returning
    /// what it completes with.
    private func write(_ promise: LeoWorkspaceFilePromise, to url: URL) async -> Error? {
        await withCheckedContinuation { continuation in
            promise.filePromiseProvider(promise, writePromiseTo: url) { continuation.resume(returning: $0) }
        }
    }

    /// Returns once `download` waits on `gate`; a download that ends
    /// first (never reaching it) fails the test instead of hanging it.
    private func untilGated(_ gate: LeoCloseGate, _ download: Task<URL, Error>) async throws {
        let ended = LeoEndedFlag()
        let watcher = Task {
            _ = await download.result
            ended.set()
        }
        defer { watcher.cancel() }
        while await gate.waiting == 0, !ended.isSet { await Task.yield() }
        try #require(await gate.waiting == 1, "the download ended before reaching its read")
    }

    @Test func onlyFileRowsOfferAFilePromise() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("folder")
        try sandbox.file("a.txt", "a")
        let harness = await makeHarness(.local, root: sandbox.root)

        let promise = try harness.promise("a.txt")

        #expect(promise.filePromiseProvider(promise, fileNameForType: promise.fileType) == "a.txt")
        #expect(promise.fileType == "public.plain-text")
        #expect(promise.operationQueue(for: promise) !== OperationQueue.main)
        #expect(harness.browser.outlineView(harness.outline, pasteboardWriterForItem: try harness.item("folder")) == nil)
        let loading = LeoWorkspaceOutlineItem(.loading(parent: sandbox.root))
        let message = LeoWorkspaceOutlineItem(.message(parent: sandbox.root, text: "x"))
        #expect(harness.browser.outlineView(harness.outline, pasteboardWriterForItem: loading) == nil)
        #expect(harness.browser.outlineView(harness.outline, pasteboardWriterForItem: message) == nil)
        await harness.tearDown()
    }

    @Test func severalFilesDragAsCopyAndSelectionSurvivesASync() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.file("a.txt", "a")
        try sandbox.file("b.txt", "b")
        try sandbox.file("c.txt", "c")
        let harness = await makeHarness(.local, root: sandbox.root)

        harness.outline.selectRowIndexes([try harness.row("a.txt"), try harness.row("c.txt")], byExtendingSelection: false)
        harness.browser.sync()

        #expect(harness.outline.allowsMultipleSelection)
        #expect(harness.outline.outsideDragOperation == .copy)
        let selected = harness.outline.selectedRowIndexes.map { harness.browser.title(ofRow: $0) }
        #expect(selected == ["a.txt", "c.txt"])
        await harness.tearDown()
    }

    @Test(arguments: kinds)
    func writingAPromiseDownloadsAndCompletesWithNil(_ kind: LeoFileBackendKind) async throws {
        let sandbox = try LeoFileSandbox()
        let drop = try LeoFileSandbox()
        defer {
            sandbox.cleanUp()
            drop.cleanUp()
        }
        try sandbox.file("a.txt", "hello")
        let harness = await makeHarness(kind, root: sandbox.root)

        let error = await write(try harness.promise("a.txt"), to: URL(fileURLWithPath: drop.path("a.txt")))

        #expect(error == nil)
        #expect(try drop.contents("a.txt") == "hello")
        #expect(harness.model.downloadsInFlight == 0)
        #expect(harness.model.downloadError == nil)
        await harness.tearDown()
    }

    @Test func aFailedPromiseShowsInTheFooterAndCompletesWithTheError() async throws {
        let sandbox = try LeoFileSandbox()
        let drop = try LeoFileSandbox()
        defer {
            sandbox.cleanUp()
            drop.cleanUp()
        }
        let path = try sandbox.file("a.txt", "hello")
        let harness = await makeHarness(.sftp, root: sandbox.root)
        let promise = try harness.promise("a.txt")
        try FileManager.default.removeItem(atPath: path)

        let error = await write(promise, to: URL(fileURLWithPath: drop.path("a.txt")))
        harness.browser.sync()

        let expected = "a.txt: " + LeoFileAccessError.notFound(path: path).localizedDescription
        #expect(error != nil)
        #expect(harness.browser.footerMessage == expected)
        #expect(expected == "a.txt: “\u{2068}a.txt\u{2069}” couldn’t be found.")
        #expect(try drop.names().isEmpty)
        harness.model.dismissDownloadError()
        harness.browser.sync()
        #expect(harness.browser.footerMessage == nil)
        await harness.tearDown()
    }

    @Test func aPathTheBrowserDoesNotShowIsNeverDownloaded() async throws {
        let sandbox = try LeoFileSandbox()
        let outside = try LeoFileSandbox()
        let drop = try LeoFileSandbox()
        defer {
            sandbox.cleanUp()
            outside.cleanUp()
            drop.cleanUp()
        }
        try sandbox.file("a.txt", "a")
        let secret = try outside.file("secret.txt", "secret")
        let harness = await makeHarness(.local, root: sandbox.root)

        await #expect(throws: LeoFileAccessError.self) {
            try await harness.model.download(secret, to: URL(fileURLWithPath: drop.path("secret.txt")))
        }
        await #expect(throws: LeoFileAccessError.self) {
            try await harness.model.download(sandbox.root, to: URL(fileURLWithPath: drop.path("root")))
        }
        #expect(try drop.names().isEmpty)
        await harness.tearDown()
    }

    @Test func theSpinnerShowsOnlyWhileADownloadIsInFlight() async throws {
        let sandbox = try LeoFileSandbox()
        let drop = try LeoFileSandbox()
        defer {
            sandbox.cleanUp()
            drop.cleanUp()
        }
        let path = try sandbox.file("a.txt", "a")
        let gate = LeoCloseGate()
        let harness = await makeHarness(.local, root: sandbox.root, accesses: [LeoGatedStreamAccess(gate: gate)])
        #expect(!harness.browser.isHeaderProgressVisible)

        let download = Task { try await harness.model.download(path, to: URL(fileURLWithPath: drop.path("a.txt"))) }
        try await untilGated(gate, download)
        harness.browser.sync()
        #expect(harness.browser.isHeaderProgressVisible)

        await gate.open()
        _ = try await download.value
        harness.browser.sync()
        #expect(!harness.browser.isHeaderProgressVisible)
        #expect(try drop.contents("a.txt") == "a")
        await harness.tearDown()
    }

    @Test func aDownloadEndingAfterReRootShowsNothing() async throws {
        let sandbox = try LeoFileSandbox()
        let other = try LeoFileSandbox()
        let drop = try LeoFileSandbox()
        defer {
            sandbox.cleanUp()
            other.cleanUp()
            drop.cleanUp()
        }
        let path = try sandbox.file("a.txt", "a")
        let gate = LeoCloseGate()
        let harness = await makeHarness(.local, root: sandbox.root, accesses: [LeoGatedStreamAccess(gate: gate)])

        let download = Task { try await harness.model.download(path, to: URL(fileURLWithPath: drop.path("a.txt"))) }
        try await untilGated(gate, download)
        await harness.model.open(LeoEditorAgentContext(host: .local, name: "other", workspace: other.root))
        await gate.open()
        await #expect(throws: LeoFileAccessError.closed) { try await download.value }
        harness.browser.sync()

        #expect(harness.model.downloadsInFlight == 0)
        #expect(harness.model.downloadError == nil)
        #expect(harness.browser.footerMessage == nil)
        #expect(!harness.browser.isHeaderProgressVisible)
        #expect(try drop.names().isEmpty)
        await harness.tearDown()
    }
}

private final class LeoEndedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Local file access whose streaming reads wait on a gate.
final class LeoGatedStreamAccess: LeoFileAccess, @unchecked Sendable {
    private let base = LeoFileAccessor.local()
    private let gate: LeoCloseGate

    init(gate: LeoCloseGate) {
        self.gate = gate
    }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    func read(_ path: String, into sink: any LeoFileByteSink) async throws -> LeoFileStat {
        await gate.wait()
        return try await base.read(path, into: sink)
    }

    func close() async { await base.close() }
}
