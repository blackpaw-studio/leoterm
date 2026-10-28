import AppKit
import GhosttyKit

/// B-059: the old tab shortcuts go to sidebar rows (D-098). Window ▸ Select
/// Next/Previous Row (⌃⇥ / ⌃⇧⇥) and Select Row ▸ Row 1–8 / Last Row
/// (⌘1–⌘9), and Ghostty's own goto_tab bindings, all land on the rows the
/// list shows and can select (`LeoSidebarModel.navigableItems`). Going to a
/// row is a single click on it.
@MainActor enum LeoRowCommands {
    /// The row-switching move a Ghostty goto_tab action asks for; nil for a
    /// value that names no tab.
    static func move(for tab: ghostty_action_goto_tab_e) -> LeoRowMove? {
        switch tab {
        case GHOSTTY_GOTO_TAB_NEXT: .next
        case GHOSTTY_GOTO_TAB_PREVIOUS: .previous
        case GHOSTTY_GOTO_TAB_LAST: .last
        default: tab.rawValue >= 1 ? .number(Int(tab.rawValue)) : nil
        }
    }

    static func canMove(model: LeoSidebarModel, terminals: LeoWindowTerminals) -> Bool {
        !items(model: model, terminals: terminals).isEmpty
    }

    /// Goes to the row `move` picks from the window's current selection.
    /// False when there is no row to go to.
    @discardableResult
    static func perform(_ move: LeoRowMove, model: LeoSidebarModel, terminals: LeoWindowTerminals, from windowID: LeoWindowID) -> Bool {
        let current = LeoSidebarSelection.current(model: model, terminals: terminals)
        guard let target = LeoRowNavigation.target(move, in: items(model: model, terminals: terminals), selected: current) else {
            return false
        }
        go(to: target, model: model, terminals: terminals, from: windowID)
        return true
    }

    /// Ghostty's goto_tab: ⇧⌘]/⇧⌘[ switch the window's editor tabs while the
    /// pane has two or more (D-460); otherwise it, ⌘N and ⌘9 go to rows.
    /// False leaves the action to Ghostty: the window has window tabs after
    /// all, or the action names no tab.
    static func gotoTab(
        _ tab: ghostty_action_goto_tab_e, editorTabs: LeoEditorTabs?, hasWindowTabs: Bool,
        model: LeoSidebarModel, terminals: LeoWindowTerminals, from windowID: LeoWindowID
    ) -> Bool {
        if LeoEditorTabNavigation.gotoTab(tab, tabs: editorTabs, hasWindowTabs: hasWindowTabs) { return true }
        guard !hasWindowTabs, let move = move(for: tab) else { return false }
        return perform(move, model: model, terminals: terminals, from: windowID)
    }

    private static func items(model: LeoSidebarModel, terminals: LeoWindowTerminals) -> [LeoSidebarItemID] {
        model.navigableItems(terminalIDs: terminals.rows.map(\.id))
    }

    /// Selects the row the way the list does, then clicks it.
    private static func go(to item: LeoSidebarItemID, model: LeoSidebarModel, terminals: LeoWindowTerminals, from windowID: LeoWindowID) {
        LeoSidebarSelection.select(item, model: model, terminals: terminals)
        switch item {
        case .agent(let id):
            guard let row = model.rows.first(where: { $0.id == id }) else { return }
            model.rowClicked(row, from: windowID)
        case .dispatch(let ref):
            model.dispatchClicked(ref, from: windowID)
        case .terminal(let id):
            terminals.activate(id)
        }
    }
}

extension TerminalController {
    /// Window ▸ Select Next Row (⌃⇥).
    @IBAction func selectNextLeoRow(_ sender: Any?) { performLeoRowMove(.next) }

    /// Window ▸ Select Previous Row (⌃⇧⇥).
    @IBAction func selectPreviousLeoRow(_ sender: Any?) { performLeoRowMove(.previous) }

    /// Window ▸ Select Row ▸ Row 1–8 (⌘1–⌘8); the item's tag is N.
    @IBAction func selectLeoRowByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag, number >= 1 else { return }
        performLeoRowMove(.number(number))
    }

    /// Window ▸ Select Row ▸ Last Row (⌘9).
    @IBAction func selectLastLeoRow(_ sender: Any?) { performLeoRowMove(.last) }

    private func performLeoRowMove(_ move: LeoRowMove) {
        guard let leoSession, let model = leoRuntime?.model else { return }
        LeoRowCommands.perform(move, model: model, terminals: leoSession.terminals, from: leoSession.id)
    }

    /// Returns nil for items that aren't the row commands'.
    func validateLeoRowMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(selectNextLeoRow(_:)), #selector(selectPreviousLeoRow(_:)),
             #selector(selectLeoRowByNumber(_:)), #selector(selectLastLeoRow(_:)):
            guard let leoSession, let model = leoRuntime?.model else { return false }
            return LeoRowCommands.canMove(model: model, terminals: leoSession.terminals)
        default:
            return nil
        }
    }
}

extension Ghostty.App {
    /// Leo: offers Ghostty's goto_tab to the window's editor tabs, then its
    /// rows, before Ghostty's own handling (see `LeoRowCommands.gotoTab`).
    static func leoGotoTab(target: ghostty_target_s, _ tab: ghostty_action_goto_tab_e) -> Bool {
        guard Thread.isMainThread, target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return false }
        let view = Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        return MainActor.assumeIsolated {
            guard let window = view.window, let controller = window.windowController as? TerminalController,
                  let session = controller.leoSession, let model = controller.leoRuntime?.model else { return false }
            return LeoRowCommands.gotoTab(
                tab, editorTabs: session.editor, hasWindowTabs: (window.tabGroup?.windows.count ?? 0) > 1,
                model: model, terminals: session.terminals, from: session.id
            )
        }
    }
}
