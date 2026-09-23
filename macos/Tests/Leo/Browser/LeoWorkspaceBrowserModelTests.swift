import Foundation
import Testing

@testable import Ghostty

/// The workspace browser's model: rooted at the agent's workspace, folders
/// listed lazily through `LeoFileAccess`, folders first then Finder order,
/// dotfiles hidden unless asked, errors kept inline. Every behaviour runs
/// against the local and the SFTP backend.
@MainActor
struct LeoWorkspaceBrowserModelTests {
    nonisolated static let kinds: [LeoFileBackendKind] = [.local, .sftp]

    private final class Opened {
        var files: [LeoEditorFileID] = []
        var failure: Error?
    }

    private func makeBrowser(
        _ kind: LeoFileBackendKind, recording listed: LeoListRecorder? = nil
    ) -> (LeoWorkspaceBrowserModel, Opened) {
        let opened = Opened()
        let browser = LeoWorkspaceBrowserModel(
            makeAccess: { _ in
                let access = kind.makeAccess()
                return listed.map { LeoListRecordingAccess(base: access, recorder: $0) } ?? access
            },
            openFile: { fileID in
                if let failure = opened.failure { throw failure }
                opened.files.append(fileID)
                return .opened
            }
        )
        return (browser, opened)
    }

    private func agent(_ workspace: String?, host: LeoHostID = .local) -> LeoEditorAgentContext {
        LeoEditorAgentContext(host: host, name: "scratch", workspace: workspace)
    }

    private func names(_ items: [LeoWorkspaceItem]) -> [String] {
        items.map { item in
            switch item {
            case let .entry(entry): entry.isFolder ? entry.name + "/" : entry.name
            case .loading: "<loading>"
            case let .message(_, text): "<\(text)>"
            }
        }
    }

    @Test(arguments: kinds)
    func listsTheWorkspaceFoldersFirstInFinderOrder(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.file("file10.txt", "")
            try sandbox.file("file2.txt", "")
            try sandbox.file("Banana", "")
            try sandbox.file("apple", "")
            try sandbox.directory("zeta")
            try sandbox.directory("Alpha")
            let (browser, _) = makeBrowser(kind)

            await browser.open(agent(sandbox.root))

            #expect(names(browser.rootItems) == ["Alpha/", "zeta/", "apple", "Banana", "file2.txt", "file10.txt"])
            await browser.close()
        }
    }

    @Test(arguments: kinds)
    func symlinksToFoldersAreFolders(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.directory("real")
            try sandbox.file("real/inside.txt", "x")
            try sandbox.file("target.md", "x")
            try sandbox.symlink("linked", to: sandbox.path("real"))
            try sandbox.symlink("AGENTS.md", to: "target.md")
            try sandbox.symlink("dangling", to: sandbox.path("missing"))
            let (browser, _) = makeBrowser(kind)

            await browser.open(agent(sandbox.root))
            await browser.expand(sandbox.path("linked"))

            #expect(names(browser.rootItems) == ["linked/", "real/", "AGENTS.md", "dangling", "target.md"])
            #expect(names(browser.items(in: sandbox.path("linked"))) == ["inside.txt"])
            await browser.close()
        }
    }

    @Test(arguments: kinds)
    func foldersAreListedOnlyWhenExpanded(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.directory("a/deep")
            try sandbox.file("a/deep/x.txt", "")
            try sandbox.directory("b")
            let recorder = LeoListRecorder()
            let (browser, _) = makeBrowser(kind, recording: recorder)

            await browser.open(agent(sandbox.root))
            #expect(recorder.paths == [sandbox.root])
            #expect(names(browser.items(in: sandbox.path("a"))) == ["<loading>"])

            await browser.expand(sandbox.path("a"))
            #expect(recorder.paths == [sandbox.root, sandbox.path("a")])
            #expect(names(browser.items(in: sandbox.path("a"))) == ["deep/"])
            #expect(browser.isExpanded(sandbox.path("a")))

            browser.collapse(sandbox.path("a"))
            await browser.expand(sandbox.path("a"))
            #expect(recorder.paths.count == 2, "re-expanding a listed folder uses what it already has")
            await browser.close()
        }
    }

    @Test(arguments: kinds)
    func dotfilesAreHiddenUntilShown(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.file(".env", "")
            try sandbox.directory(".git")
            try sandbox.file("README.md", "")
            let (browser, _) = makeBrowser(kind)
            await browser.open(agent(sandbox.root))

            #expect(names(browser.rootItems) == ["README.md"])
            browser.toggleHiddenFiles()
            #expect(browser.showsHiddenFiles)
            #expect(names(browser.rootItems) == [".git/", ".env", "README.md"])
            browser.toggleHiddenFiles()
            #expect(names(browser.rootItems) == ["README.md"])
            await browser.close()
        }
    }

    @Test(arguments: kinds)
    func reloadPicksUpChangesAndKeepsExpandedFolders(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.directory("src")
            try sandbox.file("src/a.swift", "")
            let (browser, _) = makeBrowser(kind)
            await browser.open(agent(sandbox.root))
            await browser.expand(sandbox.path("src"))

            try sandbox.file("src/b.swift", "")
            try sandbox.file("new.txt", "")
            #expect(names(browser.items(in: sandbox.path("src"))) == ["a.swift"], "never refreshes on its own")
            await browser.reload()

            #expect(names(browser.rootItems) == ["src/", "new.txt"])
            #expect(names(browser.items(in: sandbox.path("src"))) == ["a.swift", "b.swift"])
            #expect(browser.isExpanded(sandbox.path("src")))
            await browser.close()
        }
    }

    @Test(arguments: kinds)
    func aFolderThatFailsToListShowsItsErrorInline(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.directory("locked")
            try sandbox.chmod("locked", 0o000)
            let (browser, _) = makeBrowser(kind)
            await browser.open(agent(sandbox.root))

            await browser.expand(sandbox.path("locked"))

            #expect(names(browser.items(in: sandbox.path("locked"))) == ["<You don’t have permission to access “locked”.>"])
            await browser.close()
        }
    }

    @Test(arguments: kinds)
    func aMissingWorkspaceShowsItsErrorInline(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (browser, _) = makeBrowser(kind)

            await browser.open(agent(sandbox.path("gone")))

            #expect(names(browser.rootItems) == ["<“gone” couldn’t be found.>"])
            await browser.close()
        }
    }

    @Test
    func anAgentWithoutAWorkspaceSaysSo() async {
        let (browser, _) = makeBrowser(.local)

        await browser.open(agent(nil))
        #expect(names(browser.rootItems) == ["<This agent hasn’t reported a workspace.>"])
        await browser.open(agent("relative/path"))
        #expect(names(browser.rootItems) == ["<This agent hasn’t reported a workspace.>"])
        await browser.close()
    }

    @Test
    func anUnreachableHostShowsItsErrorInline() async {
        let browser = LeoWorkspaceBrowserModel(
            makeAccess: { host in throw LeoFileAccessError.unavailable(reason: "Leo isn’t connected to \(host.displayName)") },
            openFile: { _ in .opened }
        )

        await browser.open(agent("/work", host: .remote("box")))

        #expect(names(browser.rootItems) == ["<File access unavailable: Leo isn’t connected to box.>"])
        #expect(browser.root?.host == .remote("box"))
    }

    @Test(arguments: kinds)
    func opensFilesOnTheAgentsHost(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let (browser, opened) = makeBrowser(kind)
            await browser.open(agent(sandbox.root, host: .remote("box")))

            await browser.openFile(path)

            #expect(opened.files == [LeoEditorFileID(host: .remote("box"), path: path)])
            #expect(browser.openError == nil)
            await browser.close()
        }
    }

    @Test
    func aFileThatFailsToOpenShowsASanitizedErrorInline() async throws {
        let (browser, opened) = makeBrowser(.local)
        await browser.open(agent("/tmp"))
        opened.failure = LeoFileAccessError.failed(path: "/tmp/evil\u{202E}txt.exe", reason: "line one\nline two")

        await browser.openFile("/tmp/evil\u{202E}txt.exe")

        #expect(browser.openError == "Couldn’t access “eviltxt.exe”: line one line two.")
        await browser.close()
        #expect(browser.openError == nil)
    }

    @Test
    func entryNamesAreSanitizedForDisplay() {
        let entry = LeoWorkspaceEntry(name: "a\nb\u{202E}c", path: "/w/a\nb\u{202E}c", isFolder: false)
        #expect(entry.displayName == "a bc")
        #expect(LeoWorkspaceEntry(name: "\u{202E}", path: "/w/\u{202E}", isFolder: false).displayName == "\u{FFFD}")
    }

    /// Agents ▸ Browse Agent Files (⌥⌘B) opens the browser on the agent,
    /// focuses it when it's already showing that agent, and closes it from
    /// inside.
    @Test
    func browsingTheSameAgentFocusesThenCloses() async {
        let (browser, _) = makeBrowser(.local)
        let scratch = agent("/tmp")
        #expect(browser.browseStep(for: scratch, hasFocus: false) == .open)

        await browser.open(scratch)

        #expect(browser.shows(scratch))
        #expect(browser.browseStep(for: scratch, hasFocus: false) == .focus)
        #expect(browser.browseStep(for: scratch, hasFocus: true) == .close)
        let other = LeoEditorAgentContext(host: .local, name: "other", workspace: "/tmp")
        #expect(browser.browseStep(for: other, hasFocus: true) == .open)
        await browser.close()
    }

    @Test(arguments: kinds)
    func reopeningAnotherAgentStartsFresh(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.directory("one/sub")
            try sandbox.directory("two")
            try sandbox.file("two/t.txt", "")
            let (browser, _) = makeBrowser(kind)
            await browser.open(agent(sandbox.path("one")))
            await browser.expand(sandbox.path("one/sub"))

            await browser.open(agent(sandbox.path("two")))

            #expect(browser.root?.path == sandbox.path("two"))
            #expect(names(browser.rootItems) == ["t.txt"])
            #expect(!browser.isExpanded(sandbox.path("one/sub")))
            await browser.close()
            #expect(!browser.isOpen)
        }
    }
}

/// Records every folder listed, in order.
@MainActor final class LeoListRecorder {
    private(set) var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}

/// A `LeoFileAccess` that reports each `list` to a recorder.
struct LeoListRecordingAccess: LeoFileAccess {
    let base: any LeoFileAccess
    let recorder: LeoListRecorder

    func list(_ path: String) async throws -> [LeoFileEntry] {
        await recorder.record(path)
        return try await base.list(path)
    }

    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }
    func close() async { await base.close() }
}
