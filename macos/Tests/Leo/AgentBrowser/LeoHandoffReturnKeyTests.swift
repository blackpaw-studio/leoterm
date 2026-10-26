import AppKit
import Testing
import LeoKit

@testable import Ghostty

/// E3: Return answers a handoff with Done only from the pane's own chrome.
/// It never does while the user types in the page or the address bar --
/// Return there submits a login or a URL -- nor from outside the pane.
@MainActor
struct LeoHandoffReturnKeyTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private let source = FakePaneSource()
    private let page = FocusableView()
    private let outside = FocusableView()
    private let pane: LeoAgentBrowserPaneViewController
    private let window: NSWindow

    init() async {
        source.activeView = page
        pane = LeoAgentBrowserPaneViewController(source: source)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        outside.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        pane.view.frame = NSRect(x: 0, y: 20, width: 700, height: 380)
        container.addSubview(pane.view)
        container.addSubview(outside)
        window = KeyWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        source.control.send(.handoff(requestID: "ctr_1", message: "Log in please"))
        await drainMainQueue()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func pressReturn(modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
        return window.contentView!.performKeyEquivalent(with: event)
    }

    private var isStillWaiting: Bool { source.control.state.pendingHandoff != nil }

    @Test
    func returnFromPaneChromeAnswersDone() {
        #expect(window.makeFirstResponder(pane.banner.doneButton))

        #expect(pressReturn())

        #expect(source.control.state == .agent)
    }

    @Test
    func returnInThePageDoesNotAnswer() {
        #expect(window.makeFirstResponder(page))

        _ = pressReturn()

        #expect(isStillWaiting)
    }

    @Test
    func returnWhileEditingTheAddressDoesNotAnswer() {
        #expect(window.makeFirstResponder(pane.toolbar.urlField))
        #expect(pane.toolbar.urlField.currentEditor() != nil)

        _ = pressReturn()

        #expect(isStillWaiting)
    }

    @Test
    func returnFromOutsideThePaneDoesNotAnswer() {
        #expect(window.makeFirstResponder(outside))

        _ = pressReturn()

        #expect(isStillWaiting)
    }

    @Test
    func returnOnDeclineDoesNotAnswerDone() {
        #expect(window.makeFirstResponder(pane.banner.declineButton))

        _ = pressReturn()

        #expect(isStillWaiting)
    }

    @Test
    func returnWithAModifierDoesNotAnswer() {
        #expect(window.makeFirstResponder(pane.banner.doneButton))

        _ = pressReturn(modifiers: .command)

        #expect(isStillWaiting)
    }

    @Test
    func returnWithNoHandoffPendingIsLeftAlone() async {
        source.control.send(.cancelled(requestID: "ctr_1"))
        await drainMainQueue()
        #expect(window.makeFirstResponder(pane.banner.doneButton))

        #expect(!pressReturn())
    }
}
