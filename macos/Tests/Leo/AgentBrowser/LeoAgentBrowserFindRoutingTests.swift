import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-407: ⌘F, ⌘G, ⌘⇧G, Esc and the Edit ▸ Find items reach the browser pane's
/// find bar only while focus is in the pane; the editor and the terminal keep
/// their own find.
@MainActor
@Suite(.serialized)
final class LeoAgentBrowserFindRoutingTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// Stands in for a terminal surface: takes focus, answers `find:`.
    private final class TerminalStandIn: NSView {
        private(set) var finds = 0
        override var acceptsFirstResponder: Bool { true }
        @objc func find(_ sender: Any?) { finds += 1 }
    }

    private let source = FakePaneSource()
    private let finder = FakePageFinder()
    private let page: LeoAgentWebView
    private let editor = LeoEditorTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    private let editorScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    private let terminal = TerminalStandIn(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    private let pane: LeoAgentBrowserPaneViewController
    private let window: NSWindow

    init() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        page = LeoAgentWebView(frame: .zero, configuration: configuration)
        source.activeView = page
        pane = LeoAgentBrowserPaneViewController(source: source, finder: finder)
        finder.results = ["ap": LeoFindResult(index: 1, total: 3, isCapped: false)]

        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editor.usesFindBar = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        pane.view.frame = NSRect(x: 0, y: 100, width: 700, height: 500)
        editorScroll.frame = NSRect(x: 0, y: 0, width: 340, height: 90)
        terminal.frame = NSRect(x: 350, y: 0, width: 340, height: 90)
        [pane.view, editorScroll, terminal].forEach(container.addSubview)
        window = KeyWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Detaches the views while the window is alive: letting it deallocate with
    /// a web view still inside trapped the host ("Cannot form weak reference").
    deinit { LeoFixtureWindow.tearDown(window) }

    private func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }

    /// What the window does with a key equivalent: offer it down the views.
    private func press(_ character: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> Bool {
        window.contentView!.performKeyEquivalent(with: key(character, modifiers))
    }

    /// Types into the find field's editor as the user does; setting the
    /// field's string would end its editing.
    private func typeInFindField(_ text: String) async {
        let editor = pane.findBar.field.currentEditor() as? NSTextView
        editor?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        await pane.findController.settled()
    }

    @Test func cmdFWithPageFocusedShowsBarAndFocusesField() {
        #expect(window.makeFirstResponder(page))

        #expect(press("f"))

        #expect(pane.findController.isShown)
        #expect(!pane.findBar.isHidden)
        #expect(pane.findBar.field.currentEditor() != nil)
        #expect(window.firstResponder === pane.findBar.field.currentEditor())
    }

    @Test func cmdFWithURLFieldFocusedShowsBar() {
        #expect(window.makeFirstResponder(pane.toolbar.urlField))

        #expect(press("f"))

        #expect(pane.findController.isShown)
        #expect(window.firstResponder === pane.findBar.field.currentEditor())
    }

    @Test func cmdGAndShiftCmdGStepFromFieldAndPage() async {
        #expect(window.makeFirstResponder(page))
        _ = press("f")
        await typeInFindField("ap")

        #expect(press("g"))
        #expect(window.makeFirstResponder(page))
        #expect(press("g", [.command, .shift]))
        await pane.findController.settled()

        #expect(finder.calls.suffix(2) == ["next:ap", "previous:ap"])
    }

    @Test func returnAndShiftReturnStepAndEscClosesFromTheField() async throws {
        #expect(window.makeFirstResponder(page))
        _ = press("f")
        await typeInFindField("ap")
        let field = pane.findBar.field
        let editorOfField = try #require(field.currentEditor() as? NSTextView)

        #expect(pane.findBar.control(field, textView: editorOfField, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(pane.findBar.control(field, textView: editorOfField, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        await pane.findController.settled()

        #expect(finder.calls.contains("next:ap"))
        #expect(!pane.findController.isShown)
        #expect(pane.findBar.isHidden)
        #expect(finder.calls.last == "clear")
        #expect((window.firstResponder as? NSView)?.isDescendant(of: page) == true)
    }

    @Test func editFindSelectorsReachThePane() async {
        #expect(window.makeFirstResponder(page))

        #expect(page.tryToPerform(#selector(LeoAgentBrowserPaneViewController.find(_:)), with: nil))
        #expect(pane.findController.isShown)
        await typeInFindField("ap")
        #expect(page.tryToPerform(#selector(LeoAgentBrowserPaneViewController.findNext(_:)), with: nil))
        #expect(page.tryToPerform(#selector(LeoAgentBrowserPaneViewController.findPrevious(_:)), with: nil))
        await pane.findController.settled()
        #expect(finder.calls.suffix(2) == ["next:ap", "previous:ap"])

        #expect(page.tryToPerform(#selector(LeoAgentBrowserPaneViewController.findHide(_:)), with: nil))
        #expect(!pane.findController.isShown)
    }

    @Test func findHideValidatesOnlyWhileShown() {
        let item = NSMenuItem(title: "Hide Find Bar", action: #selector(LeoAgentBrowserPaneViewController.findHide(_:)), keyEquivalent: "")
        #expect(!pane.validateMenuItem(item))

        pane.findController.show()

        #expect(pane.validateMenuItem(item))
    }

    @Test func cmdFWithEditorFocusedOpensTheEditorsFindBarNotTheBrowsers() {
        #expect(window.makeFirstResponder(editor))

        #expect(press("f"))

        #expect(editorScroll.isFindBarVisible)
        #expect(!pane.findController.isShown)
    }

    @Test func cmdFWithTerminalFocusedIsNotClaimed() {
        #expect(window.makeFirstResponder(terminal))

        #expect(!press("f"))
        #expect(!pane.performFindKeyEquivalent(key("f")))
        #expect(terminal.tryToPerform(#selector(TerminalStandIn.find(_:)), with: nil))

        #expect(terminal.finds == 1)
        #expect(!pane.findController.isShown)
    }

    @Test func otherKeysAreNotClaimed() {
        #expect(window.makeFirstResponder(page))

        #expect(!pane.performFindKeyEquivalent(key("f", [.command, .option])))
        #expect(!pane.performFindKeyEquivalent(key("f", [])))
        #expect(!pane.performFindKeyEquivalent(key("h")))
        #expect(!pane.findController.isShown)
    }

    @Test func findDoesNotSendUserInput() async {
        var inputs = 0
        page.onUserInput = { inputs += 1 }
        #expect(window.makeFirstResponder(page))

        _ = press("f")
        await typeInFindField("ap")
        _ = press("g")
        _ = press("g", [.command, .shift])
        await pane.findController.settled()

        #expect(inputs == 0)
        #expect(source.control.state == .agent)
    }

    @Test func ownsFindFocusCoversThePageTheAddressBarAndTheFieldEditor() {
        #expect(window.makeFirstResponder(pane.toolbar.urlField))
        #expect(pane.ownsFindFocus(window.firstResponder))
        #expect(pane.ownsFindFocus(page))
        #expect(!pane.ownsFindFocus(terminal))
        #expect(!pane.ownsFindFocus(editor))
        #expect(!pane.ownsFindFocus(nil))
    }

    @Test func theFieldsClearButtonClearsTheQuery() async throws {
        #expect(window.makeFirstResponder(page))
        _ = press("f")
        await typeInFindField("ap")
        #expect(pane.findController.query == "ap")

        pane.findBar.field.stringValue = ""
        _ = pane.findBar.field.sendAction(pane.findBar.field.action, to: pane.findBar.field.target)
        await pane.findController.settled()

        #expect(pane.findController.query == "")
        #expect(finder.calls.last == "search:")
    }

    @Test func closingTheBarWithNoPageTakesFocusOutOfTheHiddenField() {
        source.activeView = nil
        #expect(window.makeFirstResponder(pane.toolbar.urlField))
        _ = press("f")
        #expect((window.firstResponder as? NSText)?.delegate === pane.findBar.field)

        pane.findHide(nil)

        #expect((window.firstResponder as? NSText)?.delegate !== pane.findBar.field)
        #expect(pane.findBar.isHidden)
    }
}
