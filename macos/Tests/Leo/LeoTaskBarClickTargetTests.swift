import AppKit
import Testing

@testable import Ghostty

/// The bar's click target owns the mouse-down, and acts on a click that
/// starts and ends inside it.
@MainActor struct LeoTaskBarClickTargetTests {
    private func makeView() -> (NSWindow, LeoTaskBarClickTarget.TargetView, () -> Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = LeoTaskBarClickTarget.TargetView(frame: NSRect(x: 20, y: 40, width: 100, height: 10))
        window.contentView?.addSubview(view)
        var count = 0
        view.action = { count += 1 }
        return (window, view, { count })
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    @Test func aClickInsideActsOnceOnMouseUp() {
        let (window, view, count) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 60, y: 45), in: window))
        #expect(count() == 0)
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 60, y: 45), in: window))
        #expect(count() == 1)
    }

    @Test func aPressThatEndsOutsideDoesNothing() {
        let (window, view, count) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 60, y: 45), in: window))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 160, y: 45), in: window))
        #expect(count() == 0)
    }

    @Test func aMouseUpWithoutAPressDoesNothing() {
        let (window, view, count) = makeView()
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 60, y: 45), in: window))
        #expect(count() == 0)
    }

    @Test func itTakesTheFirstClickOfAnInactiveWindowAndNeverDragsTheWindow() {
        let (_, view, _) = makeView()
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(!view.mouseDownCanMoveWindow)
    }
}
