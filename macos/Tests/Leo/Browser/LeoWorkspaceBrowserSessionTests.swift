import AppKit
import Foundation
import Testing

@testable import Ghostty

/// Each window's browser opens files in that window's editor pane, through
/// the pane's unsaved-edits prompt, and lets go of its file access when the
/// window closes.
@MainActor
struct LeoWorkspaceBrowserSessionTests {
    private func withSession(
        _ kind: LeoFileBackendKind = .local,
        access: (any LeoFileAccess)? = nil,
        _ body: (LeoWindowSession, NSWindow) async throws -> Void
    ) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let defaults = LeoInMemoryDefaults()
        let session = LeoWindowSession(window: window, defaults: defaults, makeFileAccess: { _ in access ?? kind.makeAccess() })
        try await body(session, window)
        await session.browser.close()
        await session.editor.release()
    }

    @Test(arguments: [LeoFileBackendKind.local, .sftp])
    func openingAFileShowsItInTheWindowsEditor(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let path = try sandbox.file("notes.md", "# hi")
            try await withSession(kind) { session, _ in
                await session.browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))

                await session.browser.openFile(path)

                #expect(session.editor.document?.fileID == LeoEditorFileID(host: .local, path: path))
                #expect(session.editor.document?.text == "# hi")
                #expect(session.browser.openError == nil)
            }
        }
    }

    @Test
    func aSecondFileOpensInItsOwnTabKeepingTheFirstsEdits() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let first = try sandbox.file("a.txt", "a")
            let second = try sandbox.file("b.txt", "b")
            try await withSession { session, _ in
                var asked: [String] = []
                session.editor.confirmUnsaved = { document in
                    asked.append(document.displayName)
                    return .cancel
                }
                await session.browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
                await session.browser.openFile(first)
                session.editor.document?.edit("a, edited")

                await session.browser.openFile(second)

                #expect(asked.isEmpty, "B-273: nothing is replaced, so nothing asks")
                #expect(session.editor.document?.fileID.path == second)
                #expect(session.editor.tabs.first?.document?.text == "a, edited")
                #expect(session.browser.openError == nil)
                session.editor.tabs.first?.document?.edit("a")
            }
        }
    }

    @Test
    func aFileTheEditorRefusesShowsWhyInTheBrowser() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let locked = try sandbox.file("secret.txt", "s", permissions: 0o000)
            try await withSession { session, _ in
                await session.browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))

                await session.browser.openFile(locked)

                #expect(session.editor.document == nil)
                #expect(session.browser.openError == "You don’t have permission to access “\u{2068}secret.txt\u{2069}”.")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func closingTheWindowReleasesTheBrowsersFileAccess() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoCloseSpyAccess(LeoFileAccessor.local())
            try await withSession(access: access) { session, window in
                await session.browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
                #expect(!access.isClosed)

                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

                #expect(await access.waitUntilClosed(for: .seconds(5)))
                #expect(!session.browser.isOpen)
            }
        }
    }
}
