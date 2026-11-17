import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-412: the pane's dialog bar names the agent and the site, shows the
/// page's text, and answers only on a click (or, in a prompt's own field,
/// Return and Escape).
@MainActor
struct LeoBrowserDialogBarTests {
    private static let site = LeoBrowserSite(scheme: "https", host: "shop.example.com", port: nil)

    private func prompt(_ kind: LeoBrowserDialogKind, id: Int = 1, message: String = "Delete report.pdf?", defaultText: String? = nil) -> LeoBrowserDialogPrompt {
        LeoBrowserDialogPrompt(
            agent: "alfred", dialog: LeoBrowserDialog(id: id, tab: 1, kind: kind, message: message, defaultText: defaultText, site: Self.site)
        )
    }

    private func bar(_ content: LeoBrowserDialogBar.Content?) -> (LeoBrowserDialogBar, Answers) {
        let bar = LeoBrowserDialogBar(frame: NSRect(x: 0, y: 0, width: 700, height: 120))
        let answers = Answers()
        bar.onAnswer = { answers.list.append(Answer(accept: $0, text: $1)) }
        bar.show(content)
        return (bar, answers)
    }

    struct Answer: Equatable {
        let accept: Bool
        let text: String?
    }

    @MainActor final class Answers {
        var list: [Answer] = []
    }

    @Test func confirmBarHasCancelAndOKWithNoKeyEquivalents() {
        let (bar, answers) = bar(.dialog(prompt(.confirm)))

        #expect(!bar.isHidden)
        #expect(bar.headerLabel.stringValue == "alfred · shop.example.com says:")
        #expect(bar.messageLabel.stringValue == "Delete report.pdf?")
        #expect(bar.detailLabel.stringValue == "The page is paused until you or alfred answer.")
        #expect(bar.cancelButton.title == "Cancel")
        #expect(bar.okButton.title == "OK")
        #expect(bar.textField.isHidden)
        #expect(bar.okButton.keyEquivalent.isEmpty)
        #expect(bar.cancelButton.keyEquivalent.isEmpty)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120), styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        #expect(window.defaultButtonCell == nil)
        let returnKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )
        #expect(returnKey.map { bar.performKeyEquivalent(with: $0) } == false)
        #expect(answers.list.isEmpty)
        window.close()

        bar.cancelButton.performClick(nil)
        bar.okButton.performClick(nil)
        #expect(answers.list == [Answer(accept: false, text: nil), Answer(accept: true, text: nil)])
    }

    @Test func alertBarHasOnlyOK() {
        let (bar, answers) = bar(.dialog(prompt(.alert, message: "Saved")))
        #expect(bar.cancelButton.isHidden)
        #expect(bar.okButton.title == "OK")
        bar.okButton.performClick(nil)
        #expect(answers.list == [Answer(accept: true, text: nil)])
    }

    @Test func promptBarPrefillsDefaultAndReturnInFieldAccepts() {
        let (bar, answers) = bar(.dialog(prompt(.prompt, message: "Name the report", defaultText: "Untitled")))
        #expect(!bar.textField.isHidden)
        #expect(bar.textField.stringValue == "Untitled")

        bar.textField.stringValue = "Q3"
        let editor = NSTextView()
        #expect(bar.control(bar.textField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(bar.control(bar.textField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!bar.control(bar.textField, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        bar.okButton.performClick(nil)

        #expect(answers.list == [Answer(accept: true, text: "Q3"), Answer(accept: false, text: nil), Answer(accept: true, text: "Q3")])
    }

    @Test func aRefreshOfTheSamePromptKeepsWhatTheUserTyped() {
        let (bar, _) = bar(.dialog(prompt(.prompt, defaultText: "Untitled")))
        bar.textField.stringValue = "Q3"
        bar.show(.dialog(prompt(.prompt, defaultText: "Untitled")))
        #expect(bar.textField.stringValue == "Q3")
        bar.show(.dialog(prompt(.prompt, id: 2, defaultText: "Next")))
        #expect(bar.textField.stringValue == "Next")
    }

    @Test func leaveBarOffersStayOnPageAndLeavePage() {
        let (bar, answers) = bar(.dialog(prompt(.leave, message: "page's own words")))
        #expect(bar.messageLabel.stringValue == "Leave this page? Changes you made may not be saved.")
        #expect(bar.cancelButton.title == "Stay on Page")
        #expect(bar.okButton.title == "Leave Page")
        bar.cancelButton.performClick(nil)
        #expect(answers.list == [Answer(accept: false, text: nil)])
    }

    @Test func aLongMessageShowsFourLinesWithTheRestInItsToolTip() {
        let long = String(repeating: "word ", count: 400)
        let (bar, _) = bar(.dialog(prompt(.confirm, message: long)))
        #expect(bar.messageLabel.maximumNumberOfLines == 4)
        #expect(bar.messageLabel.toolTip == long)
    }

    @Test func theHandledLineHidesTheButtons() {
        let (bar, answers) = bar(.handled("alfred answered: OK"))
        #expect(!bar.isHidden)
        #expect(bar.messageLabel.stringValue == "alfred answered: OK")
        #expect(bar.okButton.isHiddenOrHasHiddenAncestor)
        #expect(bar.headerLabel.isHidden)
        bar.okButton.performClick(nil)
        #expect(answers.list.isEmpty)
    }

    /// Narrow panes put the buttons under the text; they keep the trailing
    /// inset rather than touching the pane's edge (B-410).
    @Test(arguments: [CGFloat(460), 800])
    func buttonsKeepTheTrailingInset(width: CGFloat) {
        let bar = LeoBrowserDialogBar(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        bar.show(.dialog(prompt(.confirm)))
        bar.layoutSubtreeIfNeeded()
        let ok = bar.convert(bar.okButton.bounds, from: bar.okButton)
        #expect(abs(ok.maxX - (width - 8)) <= 1, "OK ends at \(ok.maxX) in a \(width)-wide bar")
    }

    @Test func announcesEachDialogAndTheHandledLineOnce() {
        let bar = LeoBrowserDialogBar()
        var heard: [String] = []
        bar.onAnnounce = { heard.append($0) }
        bar.show(.dialog(prompt(.confirm, id: 1)))
        bar.show(.dialog(prompt(.confirm, id: 1)))
        bar.show(.handled("alfred answered: OK"))
        bar.show(nil)
        #expect(heard == [
            "alfred · shop.example.com says: Delete report.pdf? The page is paused until you or alfred answer.",
            "alfred answered: OK",
        ])
    }
}

/// B-412: the pane shows the active tab's dialog under the permission bar,
/// its buttons answer without taking control, and the agent's answer
/// shows for a moment.
@MainActor
struct LeoBrowserDialogPaneTests {
    private static let site = LeoBrowserSite(scheme: "https", host: "shop.example.com", port: nil)

    /// Runs scheduled actions only when the test says so.
    @MainActor final class Clock {
        private(set) var delays: [Duration] = []
        private var actions: [@MainActor () -> Void] = []

        func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
            delays.append(delay)
            actions.append(action)
        }

        func runAll() {
            let due = actions
            actions = []
            due.forEach { $0() }
        }
    }

    private func openDialog(on source: FakePaneSource, tab: Int = 1) throws -> LeoBrowserDialog {
        source.fakeTabs.tabs = [LeoBrowserTabInfo(id: 1, url: nil, title: "Shop", isActive: true), LeoBrowserTabInfo(id: 2, url: nil, title: "Two", isActive: false)]
        let dialog = try #require(source.fakeTabs.dialogs.open(tab: tab, kind: .confirm, message: "Delete?", defaultText: nil, site: Self.site) { _ in })
        if tab == 1 { source.pendingDialog = LeoBrowserDialogPrompt(agent: source.key.agent, dialog: dialog) }
        source.changed()
        return dialog
    }

    @Test func barSitsUnderThePermissionBarOnlyForTheActiveTab() async throws {
        let source = FakePaneSource()
        let pane = LeoAgentBrowserPaneViewController(source: source)
        let rows = try #require(pane.view as? NSStackView).arrangedSubviews
        let permission = try #require(rows.firstIndex(of: pane.permissionBar))
        #expect(rows.firstIndex(of: pane.dialogBar) == permission + 1)
        #expect(rows.firstIndex(of: pane.findBar) == permission + 2)

        _ = try openDialog(on: source, tab: 2)
        await drainMainQueue()
        #expect(pane.dialogBar.isHidden, "a hidden tab's dialog waits without a bar")

        _ = try openDialog(on: source, tab: 1)
        await drainMainQueue()
        #expect(!pane.dialogBar.isHidden)
        #expect(pane.dialogBar.messageLabel.stringValue == "Delete?")
    }

    @Test func userAnswerDoesNotTakeControl() async throws {
        let source = FakePaneSource()
        let pane = LeoAgentBrowserPaneViewController(source: source)
        _ = pane.view
        let dialog = try openDialog(on: source)
        await drainMainQueue()

        pane.dialogBar.okButton.performClick(nil)

        #expect(source.calls == ["dialog \(dialog.id) accept"])
        #expect(source.control.state == .agent)
    }

    @Test func agentAnswerShowsHandledLineThenHides() throws {
        let source = FakePaneSource()
        let clock = Clock()
        let model = LeoAgentBrowserPaneModel(source: source, schedule: clock.schedule)
        let dialog = try openDialog(on: source)
        #expect(model.dialogBar == .dialog(LeoBrowserDialogPrompt(agent: "alpha", dialog: dialog)))

        _ = source.fakeTabs.dialogs.answer(inTab: 1, accept: true, by: .agent)
        source.pendingDialog = nil
        source.changed()

        #expect(model.dialogBar == .handled("alpha answered: OK"))
        #expect(clock.delays == [.seconds(4)])
        clock.runAll()
        #expect(model.dialogBar == nil)
    }

    @Test func theUsersOwnAnswerOrAHiddenTabsLeaveNoHandledLine() throws {
        let source = FakePaneSource()
        let clock = Clock()
        let model = LeoAgentBrowserPaneModel(source: source, schedule: clock.schedule)
        let shown = try openDialog(on: source)
        _ = source.fakeTabs.dialogs.answer(inTab: 1, dialog: shown.id, accept: true, by: .user)
        _ = try openDialog(on: source, tab: 2)
        _ = source.fakeTabs.dialogs.answer(inTab: 2, accept: true, by: .agent)

        #expect(model.dialogHandledLine == nil)
        #expect(clock.delays.isEmpty)
    }
}
