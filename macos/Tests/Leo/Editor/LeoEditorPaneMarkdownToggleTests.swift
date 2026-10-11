import AppKit
import Testing

@testable import Ghostty

/// Rendered/Raw in a real pane (B-278): Markdown opens rendered; Raw is
/// the editable text view, and what's typed there shows when switching
/// back.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LeoEditorPaneMarkdownToggleTests {
    @Test func rawEditsShowWhenRendered() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let model = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            let pane = LeoEditorPaneViewController(model: model)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = pane.view
            defer { window.contentView = nil }
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("README.md", "# Title\n")))
            #expect(await eventually { pane.contentHost.content == .markdown })
            #expect(pane.contentHost.renderedTextView.string == "Title")
            #expect(pane.canToggleRaw)

            pane.toggleRawPresentation()
            #expect(pane.contentHost.content == .text)
            pane.textView.string = "# Edited\n\nmore"
            pane.textDidChange(Notification(name: NSText.didChangeNotification, object: pane.textView))
            pane.toggleRawPresentation()

            #expect(pane.contentHost.content == .markdown)
            #expect(pane.contentHost.renderedTextView.string == "Edited\nmore")
            #expect(model.document?.isDirty == true)
            await model.release()
        }
    }

    /// The document going (left anyway, its tab closed) clears the row at
    /// once, so Quick Look has let go of the file before its folder goes --
    /// even when the preview's own close lands after the pane stops
    /// listening.
    @Test func droppingThePreviewDocumentClearsTheRow() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let model = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            let pane = LeoEditorPaneViewController(model: model)
            _ = pane.view
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("doc.pdf", "%PDF-1.4")))
            await model.document?.settlePreview()
            #expect(await eventually { if case .quickLook = pane.contentHost.content { true } else { false } })

            model.abandon()

            #expect(await eventually { pane.contentHost.content == .empty })
            #expect(!pane.contentHost.subviews.contains { $0 is LeoQuickLookPreviewView })
        }
    }

    @Test func aPlainTextFileHasNoToggle() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let model = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            let pane = LeoEditorPaneViewController(model: model)
            _ = pane.view
            try await model.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "x")))
            #expect(await eventually { pane.model.document != nil })
            #expect(!pane.canToggleRaw)
            #expect(pane.contentHost.content == .text)
            await model.release()
        }
    }

    /// The pane follows its model a main-queue turn later.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}
