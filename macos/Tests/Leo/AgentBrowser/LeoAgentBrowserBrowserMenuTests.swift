import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-409: Open in Default Browser, Copy URL and Clear Site Data for This
/// Agent… from the Browser menu (focus in the pane) and the pane's More
/// menu (any focus). None of them takes control from the agent.
@MainActor
@Suite(.serialized)
final class LeoAgentBrowserBrowserMenuTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// Stands in for a terminal surface: takes focus.
    private final class TerminalStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Records what the pane hands outside itself; Clear's answer is scripted.
    @MainActor private final class Services {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("leo-test-\(UUID().uuidString)"))
        private(set) var opened: [URL] = []
        private(set) var explained: [String] = []
        private(set) var asked: [LeoAgentBrowserKey] = []
        /// The answer to the confirmation; nil holds it until `answer(_:)`.
        var confirms: Bool? = false
        private var pending: CheckedContinuation<Bool, Never>?

        var live: LeoBrowserPaneServices {
            LeoBrowserPaneServices(
                open: { [unowned self] in opened.append($0) }, pasteboard: pasteboard,
                confirmClear: { [unowned self] key, _ in
                    asked.append(key)
                    if let confirms { return confirms }
                    return await withCheckedContinuation { pending = $0 }
                },
                explain: { [unowned self] reason, _ in explained.append(reason) }
            )
        }

        /// Answers the confirmation, whether or not it has been asked yet.
        func answer(_ confirmed: Bool) {
            guard let pending else { return confirms = confirmed }
            self.pending = nil
            pending.resume(returning: confirmed)
        }

        deinit { pasteboard.releaseGlobally() }
    }

    private static let remotePage = URL(string: "http://localhost:5173/app?q=1#top")!
    private static let forwardedPage = URL(string: "http://127.0.0.1:61000/app?q=1#top")!

    private let source = FakePaneSource()
    private let services = Services()
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
        source.key = LeoAgentBrowserKey(host: .remote("dionysus"), agent: "alpha")
        source.activeView = page
        source.activeRemoteURL = Self.remotePage
        source.externalURLResult = .success(Self.forwardedPage)
        pane = LeoAgentBrowserPaneViewController(source: source, services: services.live)
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

    /// Detaches the views while the window is alive: letting it deallocate with
    /// a web view still inside trapped the host ("Cannot form weak reference").
    deinit { LeoFixtureWindow.tearDown(window) }

    private func key(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }

    private func press(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        window.contentView!.performKeyEquivalent(with: key(character, modifiers))
    }

    private func item(_ selector: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: selector, keyEquivalent: "")
    }

    private var open: Selector { #selector(LeoAgentBrowserPaneViewController.openInDefaultBrowser(_:)) }
    private var copy: Selector { #selector(LeoAgentBrowserPaneViewController.copyBrowserURL(_:)) }
    private var clear: Selector { #selector(LeoAgentBrowserPaneViewController.clearAgentSiteData(_:)) }

    private func settle() async {
        await pane.pendingSiteAction?.value
    }

    @Test func browserItemsValidateOnPageState() {
        #expect([open, copy, clear].allSatisfy { pane.validateMenuItem(item($0)) })

        source.activeRemoteURL = URL(string: "about:blank")
        source.changed()
        #expect(!pane.validateMenuItem(item(open)))
        #expect(!pane.validateMenuItem(item(copy)))
        #expect(pane.validateMenuItem(item(clear)))

        source.activeRemoteURL = nil
        source.isClearingSiteData = true
        source.changed()
        #expect([open, copy, clear].allSatisfy { !pane.validateMenuItem(item($0)) })
    }

    @Test func browserKeysAreClaimedOnlyWithFocusInThePane() async {
        #expect(window.makeFirstResponder(terminal))
        #expect(!press("o", [.command, .option]))
        #expect(!press("C", [.command, .shift]))
        #expect(!press("\u{7F}", [.command, .shift]))
        #expect(source.calls.isEmpty)

        #expect(window.makeFirstResponder(pane.toolbar.urlField))
        #expect(press("C", [.command, .shift]))
        #expect(window.makeFirstResponder(page))
        #expect(press("o", [.command, .option]))
        await settle()
        #expect(press("\u{7F}", [.command, .shift]))
        await settle()

        #expect(services.pasteboard.string(forType: .string) == Self.remotePage.absoluteString)
        #expect(services.opened == [Self.forwardedPage])
        #expect(services.asked == [source.key])
        #expect(source.control.state == .agent)
    }

    @Test func otherKeysAreNotClaimed() {
        #expect(window.makeFirstResponder(page))

        #expect(!pane.performBrowserKeyEquivalent(key("o", [.command])))
        #expect(!pane.performBrowserKeyEquivalent(key("O", [.command, .shift])))
        #expect(!pane.performBrowserKeyEquivalent(key("c", [.command])))
        #expect(!pane.performBrowserKeyEquivalent(key("c", [.command, .option])))
        #expect(!pane.performBrowserKeyEquivalent(key("\u{7F}", [.command])))
        #expect(source.calls.isEmpty)
    }

    @Test func copyURLWritesTheURLFieldsTerms() {
        #expect(window.makeFirstResponder(page))

        #expect(page.tryToPerform(copy, with: nil))

        #expect(services.pasteboard.string(forType: .string) == Self.remotePage.absoluteString)
        #expect(services.pasteboard.string(forType: .URL) == Self.remotePage.absoluteString)
        #expect(pane.toolbar.urlField.stringValue == Self.remotePage.absoluteString)
        #expect(source.control.state == .agent)
    }

    @Test func openInDefaultBrowserOpensTheForwardedURL() async {
        #expect(window.makeFirstResponder(page))

        #expect(page.tryToPerform(open, with: nil))
        await settle()

        #expect(services.opened == [Self.forwardedPage])
        #expect(services.explained.isEmpty)
        #expect(source.control.state == .agent)
    }

    @Test func openExplainsInsteadOfOpeningWhenUnreachable() async {
        let reason = "dionysus is not connected, so port 5173 on it can't be reached"
        source.externalURLResult = .failure(LeoBrowserError(.navigationFailed, reason))
        #expect(window.makeFirstResponder(page))

        #expect(page.tryToPerform(open, with: nil))
        await settle()

        #expect(services.explained == [reason])
        #expect(services.opened.isEmpty)
    }

    @Test func clearSiteDataAsksFirstAndCancelChangesNothing() async {
        #expect(window.makeFirstResponder(page))

        #expect(page.tryToPerform(clear, with: nil))
        await settle()

        #expect(services.asked == [source.key])
        #expect(!source.calls.contains("clearSiteData"))
        #expect(pane.validateMenuItem(item(clear)))
    }

    @Test func clearSiteDataClearsOnceConfirmedAndIsOffWhileAsking() async {
        services.confirms = nil
        #expect(window.makeFirstResponder(page))

        #expect(page.tryToPerform(clear, with: nil))
        await drainMainQueue()
        #expect(!pane.validateMenuItem(item(clear)))
        services.answer(true)
        await settle()

        #expect(source.calls == ["clearSiteData"])
        #expect(pane.validateMenuItem(item(clear)))
        #expect(source.control.state == .agent)
    }

    /// The pane the menu fired in is the one cleared, whichever pane has
    /// focus by the time the user confirms.
    @Test func clearSiteDataClearsTheAgentTheAlertNamedEvenIfThePaneSwitched() async {
        let other = FakePaneSource()
        other.key = LeoAgentBrowserKey(host: .remote("dionysus"), agent: "beta")
        let otherPage = Self.makePage()
        other.activeView = otherPage
        let otherPane = LeoAgentBrowserPaneViewController(source: other, services: services.live)
        otherPane.view.frame = NSRect(x: 0, y: 0, width: 340, height: 90)
        window.contentView?.addSubview(otherPane.view)
        other.changed()
        await drainMainQueue()
        services.confirms = nil
        #expect(window.makeFirstResponder(page))

        #expect(page.tryToPerform(clear, with: nil))
        await drainMainQueue()
        #expect(window.makeFirstResponder(otherPage))
        services.answer(true)
        await settle()

        #expect(services.asked == [source.key])
        #expect(source.calls == ["clearSiteData"])
        #expect(other.calls.isEmpty)
    }

    @Test func paneMoreMenuOffersTheThreeItemsWithoutPaneFocus() throws {
        #expect(window.makeFirstResponder(terminal))
        let menu = try #require(pane.toolbar.moreMenu)

        menu.update()

        #expect(menu.items.map(\.title) == ["Open in Default Browser", "Copy URL", "", "Clear Site Data for This Agent…"])
        let actions = menu.items.filter { !$0.isSeparatorItem }
        #expect(actions.compactMap(\.action) == [open, copy, clear])
        #expect(actions.allSatisfy { $0.target === pane && $0.isEnabled })
        #expect(LeoMenuXib.shortcuts(in: menu).map(\.shortcut) == ["⌥⌘o", "⇧⌘c", "⇧⌘⌫"], "the Browser menu's shortcuts")
        let copyItem = actions[1]
        #expect(NSApp.sendAction(copy, to: copyItem.target, from: copyItem))
        #expect(services.pasteboard.string(forType: .string) == Self.remotePage.absoluteString)
    }
}
