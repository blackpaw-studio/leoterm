import AppKit
import Testing

@testable import Ghostty

/// The browser's outline, driven by the keyboard: arrows move, → / ←
/// expand and collapse (then step in and out), Return opens a file or
/// toggles a folder, Escape hands focus back. Errors show as rows.
@MainActor
struct LeoWorkspaceBrowserViewTests {
    private final class Log {
        var opened: [String] = []
        var escapes = 0
    }

    @MainActor private struct Harness {
        let model: LeoWorkspaceBrowserModel
        let browser: LeoWorkspaceBrowserViewController
        let window: NSWindow
        let log: Log

        var outline: LeoWorkspaceOutlineView { browser.outlineView }

        /// What each visible row shows, indented two spaces per level.
        var rows: [String] {
            (0..<outline.numberOfRows).map { row in
                String(repeating: "  ", count: outline.level(forRow: row)) + (browser.title(ofRow: row) ?? "?")
            }
        }

        var selectedTitle: String? { browser.title(ofRow: outline.selectedRow) }

        func select(_ title: String) throws {
            let row = try #require(rows.firstIndex { $0.trimmingCharacters(in: .whitespaces) == title })
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }

        func press(_ key: LeoTestKey) {
            outline.keyDown(with: key.event(in: window))
        }

        /// Waits for listings the view started, then shows the model.
        func settle(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            browser.sync()
            try #require(condition())
        }

        func tearDown() async {
            window.close()
            await model.close()
        }
    }

    private func makeHarness(
        _ kind: LeoFileBackendKind, root: String, access suppliedAccess: (any LeoFileAccess)? = nil
    ) async -> Harness {
        let log = Log()
        let model = LeoWorkspaceBrowserModel(
            makeAccess: { _ in suppliedAccess ?? kind.makeAccess() },
            openFile: { fileID in
                log.opened.append(fileID.path)
                return .opened
            }
        )
        let browser = LeoWorkspaceBrowserViewController(model: model)
        browser.onEscape = { log.escapes += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        await model.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: root))
        browser.sync()
        return Harness(model: model, browser: browser, window: window, log: log)
    }

    private func pasteboard(_ url: URL) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("leo-browser-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return pasteboard
    }

    private func sandbox(_ sandbox: LeoFileSandbox) throws {
        try sandbox.directory("src/deep")
        try sandbox.file("src/main.swift", "")
        try sandbox.file("README.md", "")
        try sandbox.file(".env", "")
    }

    @Test(arguments: [LeoFileBackendKind.local, .sftp])
    func showsTheTopLevelFoldersFirst(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(kind, root: files.root)

            #expect(harness.rows == ["src", "README.md"])
            #expect(harness.browser.headerTitle == (files.root as NSString).lastPathComponent)
            await harness.tearDown()
        }
    }

    @Test(arguments: [LeoFileBackendKind.local, .sftp])
    func rightArrowExpandsAFolderListingItThenStepsIn(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(kind, root: files.root)
            try harness.select("src")

            harness.press(.right)
            try await harness.settle { harness.model.items(in: files.path("src")).count == 2 }

            #expect(harness.model.isExpanded(files.path("src")))
            #expect(harness.rows == ["src", "  deep", "  main.swift", "README.md"])
            #expect(harness.selectedTitle == "src")
            harness.press(.right)
            #expect(harness.selectedTitle == "deep", "→ on an open folder steps into it")
            await harness.tearDown()
        }
    }

    @Test
    func leftArrowStepsOutThenCollapses() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(.local, root: files.root)
            await harness.model.expand(files.path("src"))
            harness.browser.sync()
            try harness.select("main.swift")

            harness.press(.left)
            #expect(harness.selectedTitle == "src")
            harness.press(.left)

            #expect(!harness.model.isExpanded(files.path("src")))
            #expect(harness.rows == ["src", "README.md"])
            await harness.tearDown()
        }
    }

    @Test
    func downArrowMovesTheSelection() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(.local, root: files.root)
            try harness.select("src")

            harness.press(.down)

            #expect(harness.selectedTitle == "README.md")
            await harness.tearDown()
        }
    }

    @Test
    func returnOpensTheSelectedFileAndTogglesAFolder() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(.local, root: files.root)
            try harness.select("README.md")

            harness.press(.return)
            try await harness.settle { harness.log.opened == [files.path("README.md")] }

            try harness.select("src")
            harness.press(.return)
            try await harness.settle { harness.model.items(in: files.path("src")).count == 2 }
            #expect(harness.model.isExpanded(files.path("src")))
            harness.press(.return)
            #expect(!harness.model.isExpanded(files.path("src")))
            #expect(harness.log.opened.count == 1, "a folder never opens in the editor")
            await harness.tearDown()
        }
    }

    @Test
    func escapeHandsFocusBack() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(.local, root: files.root)

            harness.press(.escape)

            #expect(harness.log.escapes == 1)
            await harness.tearDown()
        }
    }

    @Test
    func showingHiddenFilesAddsTheirRows() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(.local, root: files.root)

            await harness.model.toggleHiddenFiles()
            harness.browser.sync()

            #expect(harness.rows == ["src", ".env", "README.md"])
            await harness.tearDown()
        }
    }

    /// Like Finder, hidden entries shown are dimmed; the rest aren't.
    @Test
    func shownHiddenFilesAreDimmed() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try sandbox(files)
            try files.directory(".git")
            let harness = await makeHarness(.local, root: files.root)

            await harness.model.toggleHiddenFiles()
            harness.browser.sync()

            #expect(harness.rows == [".git", "src", ".env", "README.md"])
            let dimmed = harness.rows.indices.filter { harness.browser.isDimmed(row: $0) }
            #expect(dimmed.map { harness.rows[$0] } == [".git", ".env"])
            for row in harness.rows.indices {
                let cell = try #require(harness.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
                let isDimmed = dimmed.contains(row)
                #expect(cell.textField?.textColor == (isDimmed ? .secondaryLabelColor : .labelColor), "\(harness.rows[row])")
                #expect(((cell.imageView?.alphaValue ?? 0) < 1) == isDimmed, "\(harness.rows[row])")
            }
            await harness.tearDown()
        }
    }

    @Test(arguments: [LeoFileBackendKind.local, .sftp])
    func aFolderThatCantBeListedShowsWhyAsAnUnselectableRow(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { files, _ in
            try files.directory("locked")
            try files.chmod("locked", 0o000)
            let harness = await makeHarness(kind, root: files.root)
            try harness.select("locked")

            harness.press(.right)
            try await harness.settle { harness.model.folders[files.path("locked")] != .loading && harness.model.isExpanded(files.path("locked")) }

            #expect(harness.rows == ["locked", "  You don’t have permission to access “\u{2068}locked\u{2069}”."])
            harness.press(.down)
            #expect(harness.selectedTitle == "locked", "a message row can't be selected")
            await harness.tearDown()
        }
    }

    @Test
    func aFileThatFailsToOpenShowsWhyBelowTheList() async throws {
        let model = LeoWorkspaceBrowserModel(
            makeAccess: { _ in LeoFileAccessor.local() },
            openFile: { fileID in throw LeoFileAccessError.tooLarge(path: fileID.path, size: 10, limit: 1) }
        )
        let browser = LeoWorkspaceBrowserViewController(model: model)
        _ = browser.view
        await model.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: "/tmp"))
        await model.openFile("/tmp/big.log")
        browser.sync()

        #expect(browser.footerMessage?.hasPrefix("“\u{2068}big.log\u{2069}” is too large to open") == true)
        model.dismissOpenError()
        browser.sync()
        #expect(browser.footerMessage == nil)
        await model.close()
    }

    @Test
    func theListKeepsItsSelectionAcrossAReload() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try sandbox(files)
            let harness = await makeHarness(.local, root: files.root)
            try harness.select("README.md")

            try files.file("AAA.txt", "")
            await harness.model.reload()
            harness.browser.sync()

            #expect(harness.rows == ["src", "AAA.txt", "README.md"])
            #expect(harness.selectedTitle == "README.md")
            await harness.tearDown()
        }
    }

    @Test
    func controllerRoutesRootAndFolderDropsAndShowsTheMatchingProgressTarget() async throws {
        let source = try LeoFileSandbox()
        defer { source.cleanUp() }
        let rootSource = try source.file("root.txt", "root")
        let folderSource = try source.file("folder.txt", "folder")

        try await withLeoFileSandbox(.local) { files, _ in
            try files.directory("target")
            let rootGate = BrowserViewUploadGate()
            let rootHarness = await makeHarness(
                .local, root: files.root,
                access: BrowserViewGatedAccess(base: LeoFileAccessor.local(), gate: rootGate)
            )
            let rootBoard = pasteboard(URL(fileURLWithPath: rootSource))

            let rootDrag = BrowserViewDraggingInfo(rootBoard)
            #expect(rootHarness.browser.outlineView(
                rootHarness.outline, validateDrop: rootDrag, proposedItem: nil,
                proposedChildIndex: NSOutlineViewDropOnItemIndex
            ) == .copy)
            #expect(rootHarness.browser.outlineView(
                rootHarness.outline, acceptDrop: rootDrag, item: nil,
                childIndex: NSOutlineViewDropOnItemIndex
            ))
            await rootGate.waitUntilEntered()
            rootHarness.browser.sync()
            #expect(rootHarness.browser.isRootUploadProgressVisible)
            await rootGate.release()
            await awaitCondition { FileManager.default.fileExists(atPath: files.path("root.txt")) }
            await awaitCondition { await MainActor.run { rootHarness.model.uploadDestination == nil } }
            rootHarness.browser.sync()
            #expect(!rootHarness.browser.isRootUploadProgressVisible)
            await rootHarness.tearDown()

            let folderGate = BrowserViewUploadGate()
            let folderHarness = await makeHarness(
                .local, root: files.root,
                access: BrowserViewGatedAccess(base: LeoFileAccessor.local(), gate: folderGate)
            )
            let row = try #require(folderHarness.rows.firstIndex(of: "target"))
            let item = try #require(folderHarness.browser.dropItem(atRow: row))
            let folderBoard = pasteboard(URL(fileURLWithPath: folderSource))

            let folderDrag = BrowserViewDraggingInfo(folderBoard)
            #expect(folderHarness.browser.outlineView(
                folderHarness.outline, validateDrop: folderDrag, proposedItem: item,
                proposedChildIndex: NSOutlineViewDropOnItemIndex
            ) == .copy)
            #expect(folderHarness.browser.outlineView(
                folderHarness.outline, acceptDrop: folderDrag, item: item,
                childIndex: NSOutlineViewDropOnItemIndex
            ))
            await folderGate.waitUntilEntered()
            folderHarness.browser.sync()
            #expect(!folderHarness.browser.isRootUploadProgressVisible)
            #expect(folderHarness.browser.isFolderUploadProgressVisible(atRow: row))
            await folderGate.release()
            await awaitCondition { FileManager.default.fileExists(atPath: files.path("target/folder.txt")) }
            await folderHarness.tearDown()
        }
    }

    @Test
    func idleAndNoWorkspaceRowsNeverShowUploadProgress() async throws {
        try await withLeoFileSandbox(.local) { files, _ in
            try files.file("idle.txt", "")
            let harness = await makeHarness(.local, root: files.root)
            harness.browser.sync()

            #expect(!harness.browser.isRootUploadProgressVisible)
            #expect(!harness.browser.isFolderUploadProgressVisible(atRow: 0))
            await harness.tearDown()
        }

        let model = LeoWorkspaceBrowserModel(makeAccess: { _ in LeoFileAccessor.local() }, openFile: { _ in .opened })
        let browser = LeoWorkspaceBrowserViewController(model: model)
        let window = NSWindow(contentViewController: browser)
        await model.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: nil))
        browser.sync()

        #expect(!browser.isRootUploadProgressVisible)
        #expect(!browser.isFolderUploadProgressVisible(atRow: 0))
        window.close()
        await model.close()
    }
}

@MainActor
private final class BrowserViewDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

private actor BrowserViewUploadGate {
    private var blocker: CheckedContinuation<Void, Error>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func enter() async throws {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        try await withCheckedThrowingContinuation { blocker = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        blocker?.resume()
        blocker = nil
    }

    func close() {
        blocker?.resume(throwing: LeoFileAccessError.closed)
        blocker = nil
    }
}

private struct BrowserViewGatedAccess: LeoFileAccess {
    let base: any LeoFileAccess
    let gate: BrowserViewUploadGate

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }
    func create(at path: String, from source: any LeoFileByteSource) async throws -> LeoFileStat {
        try await gate.enter()
        return try await base.create(at: path, from: source)
    }
    func close() async {
        await gate.close()
        await base.close()
    }
}

enum LeoTestKey {
    case left, right, down, `return`, escape

    private var code: (UInt16, String) {
        switch self {
        case .left: (123, "\u{F702}")
        case .right: (124, "\u{F703}")
        case .down: (125, "\u{F701}")
        case .return: (36, "\r")
        case .escape: (53, "\u{1B}")
        }
    }

    @MainActor func event(in window: NSWindow) -> NSEvent {
        let (keyCode, characters) = code
        let isArrow = keyCode >= 123
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: isArrow ? [.numericPad, .function] : [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }
}
