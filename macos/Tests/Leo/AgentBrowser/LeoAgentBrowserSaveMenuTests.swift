import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-406: File ▸ Save Page as PDF… (⇧⌘S) and Save Full-Page Screenshot…
/// (⌥⇧⌘S) save the active page into the agent's workspace through a
/// one-field path sheet, and report in the download strip.
@MainActor
@Suite(.serialized)
struct LeoAgentBrowserSaveMenuTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// Stands in for a terminal surface beside the pane.
    private final class TerminalStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Takes focus inside the pane, as the page does.
    private final class PageStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private let source = FakePaneSource()
    private let tabs: FakeBrowserTabs
    private let pageView = PageStandIn(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    private let terminal = TerminalStandIn(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    private let workspace: LeoFileSandbox
    private let pane: LeoAgentBrowserPaneViewController
    private let window: NSWindow

    init() throws {
        tabs = source.fakeTabs
        workspace = try LeoFileSandbox()
        let root = workspace.root
        source.downloads = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { root })
        source.activeView = pageView
        source.activeRemoteURL = URL(string: "https://docs.example.com/guide")
        pane = LeoAgentBrowserPaneViewController(source: source)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        pane.view.frame = NSRect(x: 0, y: 100, width: 700, height: 500)
        terminal.frame = NSRect(x: 0, y: 0, width: 340, height: 90)
        [pane.view, terminal].forEach(container.addSubview)
        window = KeyWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        pane.pageSlot.addSubview(pageView)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func load(_ url: String = "https://docs.example.com/guide", title: String = "Docs") -> FakeCapturePage {
        let page = FakeCapturePage(url: URL(string: url), title: title)
        tabs.activePage = page
        return page
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    private func key(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "S", charactersIgnoringModifiers: "S", isARepeat: false, keyCode: 1)!
    }

    private func reaches(_ responder: NSResponder?) -> Bool {
        sequence(first: responder, next: { $0?.nextResponder }).contains { $0 === pane }
    }

    // MARK: - Menu

    @Test func theFileMenuHasBothItemsWithTheirShortcuts() throws {
        defer { workspace.cleanUp() }
        let shortcuts = try LeoMenuXib.shortcuts()
        let pdf = try #require(shortcuts.first { $0.action == "savePageAsPDF:" })
        let screenshot = try #require(shortcuts.first { $0.action == "saveFullPageScreenshot:" })
        #expect(pdf.title == "Save Page as PDF…")
        #expect(pdf.shortcut == "⇧⌘s")
        #expect(screenshot.title == "Save Full-Page Screenshot…")
        #expect(screenshot.shortcut == "⌥⇧⌘s")
        for taken in [pdf, screenshot] {
            #expect(shortcuts.filter { $0.shortcut == taken.shortcut }.count == 1, "\(taken.shortcut) is held once")
        }
    }

    @Test func saveItemsEnabledOnlyWithFocusInPaneAndALoadedPage() {
        defer { workspace.cleanUp() }
        let actions = [#selector(LeoAgentBrowserPaneViewController.savePageAsPDF(_:)),
                       #selector(LeoAgentBrowserPaneViewController.saveFullPageScreenshot(_:))]
        for action in actions { #expect(!pane.validateMenuItem(item(action)), "no tab") }
        _ = load("about:blank", title: "")
        for action in actions { #expect(!pane.validateMenuItem(item(action)), "a blank tab") }
        _ = load()
        for action in actions { #expect(pane.validateMenuItem(item(action))) }

        // Focus decides whether the menu reaches the pane at all.
        #expect(window.makeFirstResponder(pageView))
        #expect(reaches(window.firstResponder))
        #expect(window.makeFirstResponder(terminal))
        #expect(!reaches(window.firstResponder))
    }

    @Test func theShortcutsAreClaimedOnlyWithFocusInThePane() throws {
        defer { workspace.cleanUp() }
        _ = load()
        #expect(window.makeFirstResponder(terminal))
        #expect(!window.contentView!.performKeyEquivalent(with: key([.command, .shift])))
        #expect(pane.saveSheet == nil)

        #expect(window.makeFirstResponder(pageView))
        #expect(window.contentView!.performKeyEquivalent(with: key([.command, .shift, .option])))
        let sheet = try #require(pane.saveSheet)
        #expect(sheet.model.kind == .png)
        sheet.cancel(nil)
        #expect(pane.saveSheet == nil)
    }

    // MARK: - Sheet

    @Test func sheetDefaultsToDownloadsTitlePDFWithStemSelected() throws {
        defer { workspace.cleanUp() }
        _ = load()
        let sheet = try #require(pane.makeSaveSheet(.pdf))
        #expect(sheet.window.title == "Save Page as PDF")
        #expect(sheet.field.stringValue == "downloads/Docs.pdf")
        #expect(sheet.model.initialSelection == NSRange(location: 10, length: 4))
        #expect(sheet.saveButton.isEnabled)

        sheet.present(on: window)
        #expect(sheet.field.currentEditor()?.selectedRange == NSRange(location: 10, length: 4))
        sheet.cancel(nil)

        #expect(try #require(pane.makeSaveSheet(.png)).field.stringValue == "downloads/Docs.png")
        _ = load(title: "")
        #expect(try #require(pane.makeSaveSheet(.pdf)).field.stringValue == "downloads/docs.example.com.pdf", "untitled: the host")
    }

    @Test func invalidPathDisablesSave() throws {
        defer { workspace.cleanUp() }
        _ = load()
        let sheet = try #require(pane.makeSaveSheet(.pdf))
        var finished: [String?] = []
        sheet.onFinish = { finished.append($0) }

        for (path, problem) in [
            ("../x.pdf", "The path may not contain . or .. components."),
            ("/elsewhere/x.pdf", "The path is outside the workspace (\(workspace.root))."),
            ("x.png", "The path must end in .pdf."),
            ("  ", "The path is empty."),
        ] {
            sheet.field.stringValue = path
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.field))
            #expect(!sheet.saveButton.isEnabled, "\(path)")
            #expect(sheet.problemLabel.stringValue == problem)
            sheet.save(nil)
        }
        #expect(finished.isEmpty)

        sheet.field.stringValue = " reports/q3 "
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.field))
        #expect(sheet.saveButton.isEnabled)
        #expect(sheet.problemLabel.stringValue.isEmpty)
        sheet.save(nil)
        #expect(finished == ["reports/q3"])
    }

    // MARK: - Saving

    @Test func confirmingSavesAndShowsSavedStrip() async throws {
        defer { workspace.cleanUp() }
        let page = load()
        try workspace.directory("downloads")
        try workspace.file("downloads/Docs.pdf", "older")
        let sheet = try #require(pane.makeSaveSheet(.pdf))

        sheet.save(nil)
        await pane.pendingSave?.value

        #expect(page.captures == ["pdf"])
        #expect(try workspace.contents("downloads/Docs.pdf") == "older", "nothing is overwritten")
        #expect(try Data(contentsOf: URL(fileURLWithPath: workspace.path("downloads/Docs 2.pdf"))) == page.pdfData)
        #expect(pane.model.downloadStrip?.kind == .finished)
        #expect(pane.model.downloadStrip?.text == "Saved “Docs 2.pdf” to downloads/")
        #expect(source.control.state.allowsAgentActions, "saving is reading: the agent keeps control")
    }

    @Test func aScreenshotIsTheFullPageAndLandsWhereAsked() async throws {
        defer { workspace.cleanUp() }
        let page = load()
        let sheet = try #require(pane.makeSaveSheet(.png))
        sheet.field.stringValue = "shots/"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.field))

        sheet.save(nil)
        await pane.pendingSave?.value

        #expect(page.captures == ["screenshot full=true"])
        #expect(try workspace.names(in: "shots") == ["Docs.png"])
        #expect(pane.model.downloadStrip?.text == "Saved “Docs.png” to shots/")
    }

    @Test func aFailedSaveSaysNothingWasSavedAndStays() async throws {
        defer { workspace.cleanUp() }
        source.downloads = .withoutWorkspace()
        let pane = LeoAgentBrowserPaneViewController(source: source)
        let page = load()

        await pane.save(.pdf, of: page, at: "downloads/Docs.pdf", defaultName: "Docs.pdf")

        #expect(pane.model.downloadStrip?.kind == .failed)
        #expect(pane.model.downloadStrip?.text
            == "Couldn’t save “Docs.pdf”. \(LeoBrowserDownloadSaveError.noWorkspace.message) Nothing was saved.")
    }
}
