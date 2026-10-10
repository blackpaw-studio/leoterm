import AppKit
import GhosttyKit

/// B-273: editor tabs switch and close by menu and keyboard -- Agents ▸
/// Show Next/Previous Editor Tab (⇧⌘] / ⇧⌘[) and Close Editor Tab, and ⌘W
/// with focus in the editor (`LeoEditorPaneViewController.close(_:)`).
extension LeoMenuCommands {
    /// Show Next/Previous Editor Tab: the window's pane has two or more.
    @MainActor static func canSwitchEditorTabs(_ tabs: LeoEditorTabs?) -> Bool {
        (tabs?.tabs.count ?? 0) >= 2
    }

    /// Close Editor Tab: the window's pane has one open.
    @MainActor static func canCloseEditorTab(_ tabs: LeoEditorTabs?) -> Bool {
        tabs?.isOpen == true
    }
}

/// Ghostty's `next_tab`/`previous_tab` from the terminal (⌃Tab, ⇧⌘]): a
/// window has no tabs of its own to switch (D-098), so they switch the
/// window's editor tabs, leaving focus in the terminal.
enum LeoEditorTabNavigation {
    /// `true` when it switched an editor tab; `false` leaves the action to
    /// Ghostty: the window has window tabs after all, the pane has fewer
    /// than two tabs, or the action is another kind of goto.
    @MainActor static func gotoTab(_ tab: ghostty_action_goto_tab_e, tabs: LeoEditorTabs?, hasWindowTabs: Bool) -> Bool {
        guard !hasWindowTabs, let tabs, LeoMenuCommands.canSwitchEditorTabs(tabs) else { return false }
        switch tab {
        case GHOSTTY_GOTO_TAB_NEXT: tabs.selectNext()
        case GHOSTTY_GOTO_TAB_PREVIOUS: tabs.selectPrevious()
        default: return false
        }
        return true
    }
}

extension TerminalController {
    /// Agents ▸ Show Next Editor Tab (⇧⌘]).
    @IBAction func showNextLeoEditorTab(_ sender: Any?) {
        leoSession?.editor.selectNext()
    }

    /// Agents ▸ Show Previous Editor Tab (⇧⌘[).
    @IBAction func showPreviousLeoEditorTab(_ sender: Any?) {
        leoSession?.editor.selectPrevious()
    }

    /// Agents ▸ Close Editor Tab: the selected tab, asking first when it
    /// has unsaved edits.
    @IBAction func closeLeoEditorTab(_ sender: Any?) {
        guard let leoSession else { return }
        if let pane = leoSession.editorPane {
            pane.closeSelectedTab()
        } else {
            Task { await leoSession.editor.closeSelected() }
        }
    }

    /// Returns nil for items that aren't the editor tabs'.
    func validateLeoEditorTabMenuItem(_ item: NSMenuItem) -> Bool? {
        let tabs = leoSession?.editor
        switch item.action {
        case #selector(showNextLeoEditorTab(_:)), #selector(showPreviousLeoEditorTab(_:)):
            return LeoMenuCommands.canSwitchEditorTabs(tabs)
        case #selector(closeLeoEditorTab(_:)):
            return LeoMenuCommands.canCloseEditorTab(tabs)
        default:
            return nil
        }
    }
}

extension Ghostty.App {
    /// Leo: offers Ghostty's goto_tab to the window's editor tabs before
    /// Ghostty's own handling (see `LeoEditorTabNavigation`).
    static func leoGotoEditorTab(target: ghostty_target_s, _ tab: ghostty_action_goto_tab_e) -> Bool {
        guard Thread.isMainThread, target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return false }
        let view = Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        return MainActor.assumeIsolated {
            guard let window = view.window, let controller = window.windowController as? TerminalController else { return false }
            let hasWindowTabs = (window.tabGroup?.windows.count ?? 0) > 1
            return LeoEditorTabNavigation.gotoTab(tab, tabs: controller.leoSession?.editor, hasWindowTabs: hasWindowTabs)
        }
    }
}
