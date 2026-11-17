import AppKit
import Testing

@testable import Ghostty

/// B-408: Back and Forward list the tab's history on right-click or a press
/// and hold; a quick click still goes one page.
@MainActor
struct LeoBrowserHistoryButtonTests {
    private func entry(_ offset: Int, _ title: String, _ path: String = "p") -> LeoBrowserHistoryEntry {
        LeoBrowserHistoryEntry(offset: offset, title: title, url: URL(string: "https://example.com/\(path)")!)
    }

    private final class Recorder: NSObject {
        @objc func hit(_ sender: Any?) { clicks += 1 }
        var menus: [NSMenu] = []
        var clicks = 0
        var chosen: [LeoBrowserHistoryEntry] = []
    }

    private func make(history: [LeoBrowserHistoryEntry], press: LeoBrowserHistoryButton.Press = .click) -> (LeoBrowserHistoryButton, Recorder) {
        let button = LeoBrowserHistoryButton()
        let recorder = Recorder()
        button.history = { history }
        button.present = { menu, _ in recorder.menus.append(menu) }
        button.trackPress = { _, _ in press }
        button.onSelect = { recorder.chosen.append($0) }
        button.target = recorder
        button.action = #selector(Recorder.hit(_:))
        return (button, recorder)
    }

    private func mouseDown(on button: NSButton, rightButton: Bool = false) {
        let event = NSEvent.mouseEvent(
            with: rightButton ? .rightMouseDown : .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        if rightButton { button.rightMouseDown(with: event) } else { button.mouseDown(with: event) }
    }

    @Test func rightClickPresentsHistoryNearestFirst() throws {
        let (button, recorder) = make(history: [entry(-1, "Newest"), entry(-2, "Older")])

        mouseDown(on: button, rightButton: true)

        let menu = try #require(recorder.menus.first)
        #expect(menu.items.map(\.title) == ["Newest", "Older"])
    }

    @Test func holdPresentsMenuQuickClickGoesBack() {
        let (held, heldRecorder) = make(history: [entry(-1, "A")], press: .hold)
        let (quick, quickRecorder) = make(history: [entry(-1, "A")], press: .click)
        let (cancelled, cancelledRecorder) = make(history: [entry(-1, "A")], press: .cancel)

        mouseDown(on: held)
        mouseDown(on: quick)
        mouseDown(on: cancelled)

        #expect(heldRecorder.menus.count == 1)
        #expect(heldRecorder.clicks == 0)
        #expect(quickRecorder.menus.isEmpty)
        #expect(quickRecorder.clicks == 1)
        #expect(cancelledRecorder.menus.isEmpty)
        #expect(cancelledRecorder.clicks == 0)
    }

    @Test func choosingAnEntryReportsItsOffset() throws {
        let (button, recorder) = make(history: [entry(-1, "A"), entry(-2, "B")])
        mouseDown(on: button, rightButton: true)
        let menu = try #require(recorder.menus.first)
        let second = try #require(menu.items.last)

        _ = second.target?.perform(second.action, with: second)

        #expect(recorder.chosen.map(\.offset) == [-2])
    }

    @Test func emptyHistoryShowsNoMenu() {
        let (button, recorder) = make(history: [], press: .hold)

        mouseDown(on: button, rightButton: true)
        mouseDown(on: button)

        #expect(recorder.menus.isEmpty)
        #expect(!button.accessibilityPerformShowMenu())
    }

    @Test func titlesFallBackToURLAndTruncateAtSixty() {
        let long = String(repeating: "x", count: 80)

        #expect(LeoBrowserHistoryButton.menuTitle(for: entry(-1, "", "docs")) == "https://example.com/docs")
        #expect(LeoBrowserHistoryButton.menuTitle(for: entry(-1, "  Docs  ")) == "Docs")
        #expect(LeoBrowserHistoryButton.menuTitle(for: entry(-1, long)) == String(repeating: "x", count: 60) + "…")
        #expect(LeoBrowserHistoryButton.menuTitle(for: entry(-1, String(repeating: "y", count: 60))).count == 60)
    }

    @Test func axShowMenuPresents() {
        let (button, recorder) = make(history: [entry(-1, "A")])

        #expect(button.accessibilityPerformShowMenu())

        #expect(recorder.menus.count == 1)
    }

    @Test func aDisabledButtonIgnoresTheMouse() {
        let (button, recorder) = make(history: [entry(-1, "A")], press: .click)
        button.isEnabled = false

        mouseDown(on: button)

        #expect(recorder.clicks == 0)
    }
}
