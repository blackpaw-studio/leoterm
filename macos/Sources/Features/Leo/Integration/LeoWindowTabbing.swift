import AppKit

/// D-098: no tab bar. A window has one sidebar and one content area that
/// shows the selected row, so neither macOS nor Ghostty may group windows
/// into tabs. Anything that used to open a tab (the dock drop, Services,
/// App Intents, `TerminalController.newTab`) now gets a window of its own.
enum LeoWindowTabbing {
    /// Every terminal window's `tabbingMode`. `TerminalController.newTab`
    /// already opens a separate window for a window that disallows tabbing.
    static let mode: NSWindow.TabbingMode = .disallowed

    /// D-104's and B-057's menu titles.
    static let newTerminalTitle = "New Terminal"
    static let chooseAgentTitle = "Choose Agent…"
    static let changeWindowTitleTitle = "Change Window Title…"
    /// Choose Agent…'s key equivalent as shown to users (MainMenu.xib's
    /// ⌘O). ⌘T is New Terminal (B-066, D-125).
    static let chooseAgentShortcut = "⌘O"

    /// App-wide, before any window exists: drops Show Tab Bar, Show All
    /// Tabs, Merge All Windows and Move Tab to New Window from the Window
    /// menu, and stops the system "prefer tabs" setting grouping windows.
    @MainActor static func disableAutomaticTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// B-057: ⌘T (Ghostty's `new_tab`) makes a terminal row; the agent
    /// palette moved to its own item, File ▸ Choose Agent… (⌘O, in the
    /// xib). Close Tab would only close the window (Close Window already
    /// does), so it is hidden; its shortcut still works. The tab title is
    /// the window title (D-104).
    @MainActor static func remapMenu(newTab: NSMenuItem?, closeTab: NSMenuItem?, changeTabTitle: NSMenuItem?) {
        newTab?.title = newTerminalTitle
        closeTab?.isHidden = true
        changeTabTitle?.title = changeWindowTitleTitle
    }
}
