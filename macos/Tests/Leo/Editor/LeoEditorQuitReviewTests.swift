import AppKit
import Foundation
import Testing

@testable import Ghostty

/// Ghostty's quit review closes windows itself (no close path runs), and
/// its sheets leave other windows editable. So before it closes a window,
/// and before the quit goes ahead, editors with unsaved edits are asked
/// about again.
@MainActor
struct LeoEditorQuitReviewTests {
    private func makeRuntime() -> (LeoRuntime, UserDefaults) {
        let defaults = LeoInMemoryDefaults()
        let activity = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        return (LeoRuntime(daemon: QuitReviewDaemon(), cli: LeoCLI(), activitySource: activity, defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner()), defaults)
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func editsInTheWindowsItClosesAreAskedAboutFirst() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (runtime, defaults) = makeRuntime()
            var asked: [String] = []
            let (reviewed, other) = (window(), window())
            // The registry holds sessions weakly; their windows' controllers
            // own them.
            var sessions: [LeoWindowSession] = []
            for (window, name) in [(reviewed, "a.txt"), (other, "b.txt")] {
                let session = runtime.registry.makeSession(window: window, defaults: defaults, makeFileAccess: { _ in LeoFileAccessor.local() })
                session.editor.confirmUnsaved = { document in
                    asked.append(document.displayName)
                    return .discard
                }
                try await session.editor.open(LeoEditorFileID(host: .local, path: try sandbox.file(name, name)))
                session.editor.document?.edit("edited")
                sessions.append(session)
            }
            let editors = sessions.map(\.editor)

            #expect(await runtime.resolveUnsavedEdits(in: [reviewed]))
            #expect(asked == ["a.txt"])
            #expect(editors[1].document?.isDirty == true)

            #expect(await runtime.resolveUnsavedEdits())
            #expect(asked == ["a.txt", "b.txt"])
            #expect(editors.allSatisfy { $0.document == nil })
        }
    }
}

/// The "leave anyway?" offer is a sheet on the stuck editor's own window,
/// not whichever window is key.
@MainActor
struct LeoEditorEntryWindowTests {
    @Test func anEditorsEntryNamesItsWindow() throws {
        let defaults = LeoInMemoryDefaults()
        let activity = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: QuitReviewDaemon(), cli: LeoCLI(), activitySource: activity, defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let session = runtime.registry.makeSession(window: window, defaults: defaults)

        #expect(runtime.editorEntry(for: session).window() === window)
        #expect(LeoUnsavedEditorsGate.Entry(editor: session.editor) {}.window() == nil)
    }
}

/// The offer to leave anyway goes on the frontmost sheet of the editor's
/// window -- over a sheet already up there, not queued behind it (B-022).
@MainActor
struct LeoEditorAlertSheetHostTests {
    @Test func theOfferGoesOnTheFrontmostSheet() throws {
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        let parent = window()
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        #expect(LeoEditorAlerts.sheetHost(for: parent) === parent)

        let sheet = window()
        let nested = window()
        parent.beginSheet(sheet, completionHandler: nil)
        sheet.beginSheet(nested, completionHandler: nil)
        defer {
            sheet.endSheet(nested)
            parent.endSheet(sheet)
        }
        try #require(parent.attachedSheet === sheet)

        #expect(LeoEditorAlerts.sheetHost(for: parent) === nested)
    }
}

actor QuitReviewDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func start(_ name: String) async throws {}
    func stop(_ name: String, wakeOnMessage: Bool?) async throws {}
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_ name: String) async throws {}
    func setTemplate(_ name: String, template: String) async throws {}
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws {}
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_ name: String, lines: Int?) async throws -> String { "" }
}
