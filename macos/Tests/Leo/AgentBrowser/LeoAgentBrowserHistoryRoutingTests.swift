import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-408: ⌘[, ⌘], ⌘⇧T and the History menu's items reach the browser pane only
/// while focus is in the pane; the terminal keeps its own meaning for those keys.
@MainActor
@Suite(.serialized)
struct LeoAgentBrowserHistoryRoutingTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// Stands in for a terminal surface: takes focus, answers the split and undo actions.
    private final class TerminalStandIn: NSView {
        private(set) var undos = 0
        override var acceptsFirstResponder: Bool { true }
        @objc func undo(_ sender: Any?) { undos += 1 }
    }

    private let source = FakePaneSource()
    private let page: LeoAgentWebView
    private let terminal = TerminalStandIn(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    private let pane: LeoAgentBrowserPaneViewController
    private let window: NSWindow

    private static func makePage() -> LeoAgentWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return LeoAgentWebView(frame: .zero, configuration: configuration)
    }

    init() async {
        page = Self.makePage()
        source.activeView = page
        source.canGoBack = true
        source.canGoForward = true
        source.canReopenClosedTab = true
        pane = LeoAgentBrowserPaneViewController(source: source)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        pane.view.frame = NSRect(x: 0, y: 100, width: 700, height: 500)
        terminal.frame = NSRect(x: 350, y: 0, width: 340, height: 90)
        [pane.view, terminal].forEach(container.addSubview)
        window = KeyWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        source.changed()
        await drainMainQueue()
    }

    private func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }

    private func press(_ character: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> Bool {
        window.contentView!.performKeyEquivalent(with: key(character, modifiers))
    }

    private func item(_ selector: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: selector, keyEquivalent: "")
    }

    @Test func cmdShiftTInPaneReopens() {
        #expect(window.makeFirstResponder(page))

        #expect(press("t", [.command, .shift]))
        #expect(press("T", [.command, .shift]))

        #expect(source.calls == ["reopenClosedTab", "reopenClosedTab"])
        #expect(source.control.state == .user)
    }

    @Test func cmdBracketsInPageAndURLFieldGoBackForward() {
        #expect(window.makeFirstResponder(page))
        #expect(press("["))
        #expect(press("]"))
        #expect(window.makeFirstResponder(pane.toolbar.urlField))
        #expect(press("["))
        #expect(press("]"))

        #expect(source.calls == ["back", "forward", "back", "forward"])
    }

    @Test func historyKeysWithTerminalFocusedAreNotClaimed() {
        #expect(window.makeFirstResponder(terminal))

        #expect(!press("["))
        #expect(!press("]"))
        #expect(!press("t", [.command, .shift]))
        #expect(!pane.performHistoryKeyEquivalent(key("t", [.command, .shift])))

        #expect(source.calls.isEmpty)
        #expect(source.control.state == .agent)
    }

    @Test func otherKeysAreNotClaimed() {
        #expect(window.makeFirstResponder(page))

        #expect(!pane.performHistoryKeyEquivalent(key("t")))
        #expect(!pane.performHistoryKeyEquivalent(key("t", [.command, .option])))
        #expect(!pane.performHistoryKeyEquivalent(key("[", [.command, .shift])))
        #expect(!pane.performHistoryKeyEquivalent(key("[", [])))
        #expect(source.calls.isEmpty)
    }

    @Test func historyMenuSelectorsReachThePaneAndValidate() {
        let back = item(#selector(LeoAgentBrowserPaneViewController.browserGoBack(_:)))
        let forward = item(#selector(LeoAgentBrowserPaneViewController.browserGoForward(_:)))
        let reopen = item(#selector(LeoAgentBrowserPaneViewController.reopenClosedTab(_:)))
        #expect(window.makeFirstResponder(page))
        #expect([back, forward, reopen].allSatisfy(pane.validateMenuItem))

        #expect(page.tryToPerform(#selector(LeoAgentBrowserPaneViewController.browserGoBack(_:)), with: nil))
        #expect(page.tryToPerform(#selector(LeoAgentBrowserPaneViewController.browserGoForward(_:)), with: nil))
        #expect(page.tryToPerform(#selector(LeoAgentBrowserPaneViewController.reopenClosedTab(_:)), with: nil))
        #expect(source.calls == ["back", "forward", "reopenClosedTab"])
        #expect(!terminal.tryToPerform(#selector(LeoAgentBrowserPaneViewController.browserGoBack(_:)), with: nil))

        source.canGoBack = false
        source.canGoForward = false
        source.canReopenClosedTab = false
        source.changed()
        #expect([back, forward, reopen].allSatisfy { !pane.validateMenuItem($0) })
    }

    @Test func cmdShiftTWithNothingClosedIsClaimedAndSendsNoInput() {
        source.canReopenClosedTab = false
        #expect(window.makeFirstResponder(page))

        #expect(press("t", [.command, .shift]))

        #expect(source.calls.isEmpty)
        #expect(source.control.state == .agent)
    }

    @Test func closingTheFocusedTabFocusesTheNextPage() {
        #expect(window.makeFirstResponder(page))
        let next = Self.makePage()

        source.viewHost.release(page)
        source.activeView = next
        source.viewHost.refresh(source)

        #expect((window.firstResponder as? NSView)?.isDescendant(of: next) == true)
        #expect(press("t", [.command, .shift]))
    }

    @Test func closingTheLastFocusedTabKeepsFocusInPane() {
        #expect(window.makeFirstResponder(page))

        source.viewHost.release(page)
        source.activeView = nil
        source.viewHost.refresh(source)

        #expect(window.firstResponder === pane.pageSlot)
        #expect(press("t", [.command, .shift]))
        #expect(source.calls == ["reopenClosedTab"])
    }

    @Test func aPageThatIsNotFocusedLeavesFocusAlone() {
        #expect(window.makeFirstResponder(terminal))
        let next = Self.makePage()

        source.viewHost.release(page)
        source.activeView = next
        source.viewHost.refresh(source)

        #expect(window.firstResponder === terminal)
    }
}
