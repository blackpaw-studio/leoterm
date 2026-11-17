import AppKit
import LeoKit

/// What the browser pane's Open, Copy and Clear reach outside the pane
/// (B-409), so tests never open a browser, write the general pasteboard or
/// show a sheet.
struct LeoBrowserPaneServices {
    /// Hands a page to the system's default browser.
    var open: @MainActor (URL) -> Void
    var pasteboard: NSPasteboard
    /// Asks before clearing `key`'s site data; true only for Clear.
    var confirmClear: @MainActor (_ key: LeoAgentBrowserKey, _ window: NSWindow?) async -> Bool
    /// Says why the page can't be opened.
    var explain: @MainActor (_ reason: String, _ window: NSWindow?) -> Void

    static var live: Self {
        Self(
            open: { _ = NSWorkspace.shared.open($0) },
            pasteboard: .general,
            confirmClear: { await LeoClearSiteDataConfirmation.confirm(agent: $0, in: $1) },
            explain: { LeoClearSiteDataConfirmation.explain($0, in: $1) }
        )
    }
}

/// Open Location, Open in Default Browser, Copy URL and Clear Site Data for This Agent…
/// (B-409). The Browser menu's items reach these through the responder chain
/// while focus is anywhere in the pane, and the pane's stack claims ⌥⌘O, ⇧⌘C
/// and ⇧⌘⌫ (and ⌘L) under the same condition, as Find and History do (D-843, D-860).
/// The More menu aims its items at the pane, so they work wherever focus is.
/// None of them is input to the page, so none takes control from the agent.
extension LeoAgentBrowserPaneViewController {
    static let openInDefaultBrowserTitle = "Open in Default Browser"
    static let copyURLTitle = "Copy URL"
    static let clearSiteDataTitle = "Clear Site Data for This Agent…"

    /// What the key equivalent asks for: ⌥⌘O, ⇧⌘C or ⇧⌘⌫; nil for any other key.
    static func browserAction(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("l", [.command]): return #selector(focusAddressBar(_:))
        case ("o", [.command, .option]): return #selector(openInDefaultBrowser(_:))
        case ("c", [.command, .shift]): return #selector(copyBrowserURL(_:))
        case ("\u{7F}", [.command, .shift]), ("\u{8}", [.command, .shift]): return #selector(clearAgentSiteData(_:))
        default: return nil
        }
    }

    func performBrowserKeyEquivalent(_ event: NSEvent) -> Bool {
        guard ownsFindFocus(view.window?.firstResponder), let action = Self.browserAction(for: event) else { return false }
        perform(action, with: nil)
        return true
    }

    /// Open Location (⌘L): the address bar takes focus with its text selected.
    @objc func focusAddressBar(_ sender: Any?) {
        toolbar.focusAddress()
    }

    /// The pane's More menu: the Browser menu's items, aimed at this pane.
    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu(title: "More")
        let items = [
            moreItem(Self.openInDefaultBrowserTitle, #selector(openInDefaultBrowser(_:)), "o", [.command, .option]),
            moreItem(Self.copyURLTitle, #selector(copyBrowserURL(_:)), "c", [.command, .shift]),
            .separator(),
            moreItem(Self.clearSiteDataTitle, #selector(clearAgentSiteData(_:)), "\u{8}", [.command, .shift]),
        ]
        items.forEach(menu.addItem)
        return menu
    }

    private func moreItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    /// The page's address as the address bar shows it, in the agent's terms;
    /// nil with no page or a blank tab.
    private var copyableURL: URL? {
        guard let url = model.source.activeRemoteURL, url.absoluteString.lowercased() != "about:blank" else { return nil }
        return url
    }

    private var canOpenInDefaultBrowser: Bool {
        model.source.activeRemoteURL.map(LeoBrowserURLPolicy.isExternallyOpenable) ?? false
    }

    private var canClearSiteData: Bool {
        !isConfirmingClear && !model.source.isClearingSiteData
    }

    /// Opens the page the user sees in the default browser: a remote
    /// loopback page through its machine's forward, or a sheet saying why it
    /// can't be reached.
    @objc func openInDefaultBrowser(_ sender: Any?) {
        guard canOpenInDefaultBrowser else { return NSSound.beep() }
        let source = model.source
        pendingSiteAction = Task { [weak self, services] in
            do {
                guard let url = try await source.externalURL() else { return NSSound.beep() }
                services.open(url)
            } catch {
                services.explain((error as? LeoBrowserError)?.message ?? error.localizedDescription, self?.view.window)
            }
        }
    }

    /// Copies the address bar's URL, as a URL and as plain text.
    @objc func copyBrowserURL(_ sender: Any?) {
        guard let url = copyableURL else { return NSSound.beep() }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        services.pasteboard.clearContents()
        services.pasteboard.writeObjects([item])
    }

    /// Asks, then empties this pane's agent's store. The browser is the one
    /// this pane showed when the command came, whatever has focus once the
    /// user answers.
    @objc func clearAgentSiteData(_ sender: Any?) {
        guard canClearSiteData else { return NSSound.beep() }
        let source = model.source
        isConfirmingClear = true
        pendingSiteAction = Task { [weak self, services] in
            let confirmed = await services.confirmClear(source.key, self?.view.window)
            self?.isConfirmingClear = false
            if confirmed { await source.clearSiteData() }
        }
    }

    /// nil for an item that isn't a Browser item.
    func validateBrowserItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(openInDefaultBrowser(_:)): canOpenInDefaultBrowser
        case #selector(copyBrowserURL(_:)): copyableURL != nil
        case #selector(clearAgentSiteData(_:)): canClearSiteData
        default: nil
        }
    }
}
