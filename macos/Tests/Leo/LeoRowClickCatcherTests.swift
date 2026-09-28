import AppKit
import Testing

@testable import Ghostty

/// B-048: the row click catcher reports a click from the mouse events
/// themselves -- their own modifiers and click count -- and only a click
/// that starts and ends inside the row.
@MainActor struct LeoRowClickCatcherTests {
    private struct Click: Equatable {
        let modifierFlags: NSEvent.ModifierFlags
        let clickCount: Int
    }

    private final class Harness {
        let window: NSWindow
        let catcher = LeoRowClickCatcherView(frame: NSRect(x: 20, y: 20, width: 100, height: 40))
        var clicks: [Click] = []

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(catcher)
            catcher.onClick = { [unowned self] in clicks.append(Click(modifierFlags: $0, clickCount: $1)) }
        }

        static let inside = NSPoint(x: 60, y: 40)
        static let outside = NSPoint(x: 160, y: 160)

        func send(_ type: NSEvent.EventType, at point: NSPoint, _ flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
            if let event { catcher.handle(event) }
        }

        func click(at point: NSPoint = inside, _ flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
            send(.leftMouseDown, at: point, flags, clickCount: clickCount)
            send(.leftMouseUp, at: point, flags, clickCount: clickCount)
        }
    }

    @Test func reportsTheClicksOwnModifiersAndCount() {
        let harness = Harness()

        harness.click(.command)
        harness.click([.option], clickCount: 2)

        #expect(harness.clicks == [Click(modifierFlags: .command, clickCount: 1), Click(modifierFlags: .option, clickCount: 2)])
    }

    @Test func ignoresClicksOutsideTheRowAndDragsInOrOut() {
        let harness = Harness()

        harness.click(at: Harness.outside)
        harness.send(.leftMouseDown, at: Harness.outside)
        harness.send(.leftMouseUp, at: Harness.inside)
        harness.send(.leftMouseDown, at: Harness.inside)
        harness.send(.leftMouseUp, at: Harness.outside)

        #expect(harness.clicks.isEmpty)
    }

    @Test func controlClickIsTheContextMenuNotARowClick() {
        let harness = Harness()

        harness.click(.control)

        #expect(harness.clicks.isEmpty)
    }

    @Test func aDisabledRowIgnoresClicks() {
        let harness = Harness()
        harness.catcher.isEnabled = false

        harness.click()

        #expect(harness.clicks.isEmpty)
    }

    /// B-049: rows re-sort live and SwiftUI may hand this view to another
    /// row (a new `identity` and `onClick`) between mouse-down and
    /// mouse-up. That mouse-up is not a click on the new row.
    @Test func aClickWhoseRowChangedBeforeMouseUpIsDropped() {
        let harness = Harness()
        harness.catcher.identity = "alpha"
        var otherRowClicks = 0

        harness.send(.leftMouseDown, at: Harness.inside)
        harness.catcher.identity = "bravo"
        harness.catcher.onClick = { _, _ in otherRowClicks += 1 }
        harness.send(.leftMouseUp, at: Harness.inside)

        #expect(harness.clicks.isEmpty)
        #expect(otherRowClicks == 0)
    }

    @Test func aClickOnTheSameRowSurvivesARebind() {
        let harness = Harness()
        harness.catcher.identity = "alpha"
        var reboundClicks = 0

        harness.send(.leftMouseDown, at: Harness.inside)
        harness.catcher.identity = "alpha"
        harness.catcher.onClick = { _, _ in reboundClicks += 1 }
        harness.send(.leftMouseUp, at: Harness.inside)

        #expect(reboundClicks == 1)
    }

    @Test func neverTakesTheClickFromTheListOrRow() {
        let harness = Harness()

        #expect(harness.catcher.hitTest(Harness.inside) == nil)
    }
}
