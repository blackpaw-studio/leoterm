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

    private func makeHarness(_ kind: LeoFileBackendKind, root: String) async -> Harness {
        let log = Log()
        let model = LeoWorkspaceBrowserModel(
            makeAccess: { _ in kind.makeAccess() },
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

            harness.model.toggleHiddenFiles()
            harness.browser.sync()

            #expect(harness.rows == ["src", ".env", "README.md"])
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

            #expect(harness.rows == ["locked", "  You don’t have permission to access “locked”."])
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

        #expect(browser.footerMessage?.hasPrefix("“big.log” is too large to open") == true)
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
