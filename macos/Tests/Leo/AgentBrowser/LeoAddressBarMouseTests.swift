import AppKit
import Testing

@testable import Ghostty

extension LeoAppEventQueueTests {
/// B-420, B-428: the address bar's click and drag, through the field's own
/// mouse tracking. The tracking loop takes its mouse-up (and drags) off the
/// process-wide event queue, so these run with the other suites that touch
/// it (`LeoEventQueueGuardTests`): a mouse-up posted by a test running at the
/// same time ends the click early, at its own location, and leaves a partial
/// selection ({3, 20} for {0, 23}).
@MainActor
struct LeoAddressBarMouseTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// An unfocused address bar in a key window, laid out.
    private func unfocusedAddressField() async throws -> (field: LeoAddressField, window: KeyWindow) {
        let source = FakePaneSource()
        source.activeRemoteURL = URL(string: "https://example.com/one")
        let pane = LeoAgentBrowserPaneViewController(source: source)
        pane.view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = KeyWindow(contentRect: pane.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        source.changed()
        await drainMainQueue()
        pane.view.layoutSubtreeIfNeeded()
        return (pane.toolbar.urlField, window)
    }

    /// A left-mouse event at `point` (field coordinates), as the window gets it.
    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in field: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: field.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func clickingIntoAnUnfocusedAddressBarSelectsAllText() async throws {
        let (field, window) = try await unfocusedAddressField()
        let point = NSPoint(x: 20, y: field.bounds.midY)
        // The mouse-up is already queued, so super's drag tracking ends at once.
        NSApp.postEvent(Self.mouse(.leftMouseUp, at: point, in: field, window: window), atStart: false)

        field.mouseDown(with: Self.mouse(.leftMouseDown, at: point, in: field, window: window))

        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange == NSRange(location: 0, length: field.stringValue.utf16.count))
    }

    @Test func draggingInAnUnfocusedAddressBarSelectsOnlyThePartDraggedOver() async throws {
        let (field, window) = try await unfocusedAddressField()
        let start = NSPoint(x: 20, y: field.bounds.midY)
        let end = NSPoint(x: 60, y: field.bounds.midY)
        NSApp.postEvent(Self.mouse(.leftMouseDragged, at: end, in: field, window: window), atStart: false)
        NSApp.postEvent(Self.mouse(.leftMouseUp, at: end, in: field, window: window), atStart: false)

        field.mouseDown(with: Self.mouse(.leftMouseDown, at: start, in: field, window: window))

        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange.length > 0)
        #expect(editor.selectedRange.length < field.stringValue.utf16.count)
    }
}
}
