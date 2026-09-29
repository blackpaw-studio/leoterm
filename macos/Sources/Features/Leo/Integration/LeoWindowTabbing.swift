import AppKit

/// D-098: no tab bar. A window has one sidebar and one content area that
/// shows the selected row, so neither macOS nor Ghostty may group windows
/// into tabs. Anything that used to open a tab (the dock drop, Services,
/// App Intents, `TerminalController.newTab`) now gets a window of its own.
enum LeoWindowTabbing {
    /// Every terminal window's `tabbingMode`. `TerminalController.newTab`
    /// already opens a separate window for a window that disallows tabbing.
    static let mode: NSWindow.TabbingMode = .disallowed

    /// D-104's menu titles.
    static let chooseAgentTitle = "Choose Agent…"
    static let changeWindowTitleTitle = "Change Window Title…"

    /// App-wide, before any window exists: drops Show Tab Bar, Show All
    /// Tabs, Merge All Windows and Move Tab to New Window from the Window
    /// menu, and stops the system "prefer tabs" setting grouping windows.
    @MainActor static func disableAutomaticTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// D-104: ⌘T keeps opening the agent palette, whose choice (an agent
    /// or a plain shell) now shows in the window's content area, so it is
    /// named for that. Close Tab would only close the window (Close Window
    /// already does), so it is hidden; its shortcut still works. The tab
    /// title is the window title.
    @MainActor static func remapMenu(newTab: NSMenuItem?, closeTab: NSMenuItem?, changeTabTitle: NSMenuItem?) {
        newTab?.title = chooseAgentTitle
        closeTab?.isHidden = true
        changeTabTitle?.title = changeWindowTitleTitle
    }
}
