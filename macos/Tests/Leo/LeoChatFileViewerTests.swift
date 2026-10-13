import AppKit
import Testing

@testable import Ghostty

/// The chat pane's read-only file view: what it shows, that it never edits,
/// and when Escape means Back.
@MainActor
struct LeoChatFileViewerTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-view-\(UUID().uuidString)", isDirectory: true)

    private func document(_ filename: String, body: LeoChatViewerDocument.Body, bytes: Data? = nil) throws -> LeoChatViewerDocument {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        if let bytes { try bytes.write(to: url) }
        return LeoChatViewerDocument(attachmentID: "a1", filename: filename, url: url, body: body)
    }

    private func makeViewer(openExternally: @escaping (URL) -> Void = { _ in }) -> LeoChatFileViewerView {
        LeoChatFileViewerView(openExternally: openExternally, onBack: {})
    }

    @Test func textShowsReadOnly() throws {
        let viewer = makeViewer()
        viewer.show(try document("notes.txt", body: .text("hello", .text)))
        #expect(viewer.contentHost.content == .text)
        #expect(viewer.contentHost.textView.string == "hello")
        #expect(!viewer.contentHost.textView.isEditable)
    }

    @Test func markdownShowsRendered() throws {
        let viewer = makeViewer()
        viewer.show(try document("notes.md", body: .text("# Title", .rendered(.markdown))))
        #expect(viewer.contentHost.content == .markdown)
        #expect(!viewer.contentHost.textView.isEditable)
    }

    @Test func anImageShowsFromItsFile() throws {
        let viewer = makeViewer()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let doc = try document("shot.png", body: .file(.image), bytes: png)
        viewer.show(doc)
        #expect(viewer.contentHost.content == .image(doc.url))
        #expect(viewer.contentHost.imagePreview != nil)
    }

    @Test func anUndecodableImageOffersTheDefaultApp() throws {
        var opened: [URL] = []
        let viewer = makeViewer(openExternally: { opened.append($0) })
        let doc = try document("broken.png", body: .file(.image), bytes: Data([1, 2, 3]))
        viewer.show(doc)
        let unavailable = try #require(viewer.contentHost.subviews.first as? LeoUnavailablePreviewView)
        unavailable.onAction(.reveal)
        #expect(opened == [doc.url])
    }

    @Test(arguments: [
        (UInt16(53), NSEvent.ModifierFlags(), true, false, false, true),
        (UInt16(53), NSEvent.ModifierFlags.option, true, false, false, false),
        (UInt16(53), NSEvent.ModifierFlags.command, true, false, false, false),
        (UInt16(53), NSEvent.ModifierFlags(), true, true, false, false),
        (UInt16(53), NSEvent.ModifierFlags(), false, false, false, false),
        (UInt16(36), NSEvent.ModifierFlags(), true, false, false, false),
        (UInt16(53), NSEvent.ModifierFlags(), false, false, true, true),
        (UInt16(53), NSEvent.ModifierFlags(), false, true, true, false),
        (UInt16(53), NSEvent.ModifierFlags.option, false, false, true, false),
    ])
    func escapeClosesOnlyFromTheViewerItself(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isInViewer: Bool, isFieldEditor: Bool, coversWindow: Bool, closes: Bool
    ) {
        #expect(
            LeoChatFileViewerView.closesOnEscape(
                keyCode: keyCode, modifiers: modifiers, isInViewer: isInViewer, isFieldEditor: isFieldEditor, coversWindow: coversWindow
            ) == closes
        )
    }

    // MARK: Find

    /// Find… is wired to `find:` (the terminal's search), which a text view
    /// doesn't answer; the viewer's text views must, or ⌘F shows nothing.
    private func viewerInWindow(_ document: LeoChatViewerDocument) -> (LeoChatFileViewerView, NSWindow) {
        let viewer = makeViewer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = viewer
        viewer.show(document)
        viewer.layoutSubtreeIfNeeded()
        return (viewer, window)
    }

    @Test(arguments: [("notes.txt", false), ("notes.md", true)])
    func findShowsTheFindBarInTheShownText(filename: String, rendered: Bool) throws {
        let body = LeoChatViewerDocument.Body.text("hello world", rendered ? .rendered(.markdown) : .text)
        let (viewer, window) = viewerInWindow(try document(filename, body: body))
        let target = try #require(viewer.contentHost.focusTarget as? NSTextView)
        window.makeFirstResponder(target)
        let scrollView = try #require(target.enclosingScrollView)
        #expect(target.usesFindBar)
        #expect(!scrollView.isFindBarVisible)
        #expect(target.tryToPerform(Selector(("find:")), with: nil))
        #expect(scrollView.isFindBarVisible)
    }

    @Test(arguments: ["findNext:", "findPrevious:"])
    func findNextAndPreviousAreAnsweredByTheShownText(action: String) throws {
        let (viewer, _) = viewerInWindow(try document("notes.md", body: .text("hello", .rendered(.markdown))))
        let target = try #require(viewer.contentHost.focusTarget as? NSTextView)
        #expect(target.responds(to: Selector((action))))
    }
}
