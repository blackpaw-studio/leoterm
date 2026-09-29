import AppKit
import GhosttyKit
import SwiftUI

extension TerminalController {
    /// The Leo runtime singleton, when the app delegate has one installed.
    var leoRuntime: LeoRuntime? { (NSApp.delegate as? AppDelegate)?.leoRuntime }

    /// The sidebar row currently selected in this window's Leo runtime, if
    /// any. Menu commands that act "on the current sidebar selection" read
    /// this rather than duplicating `LeoSidebarModel`'s selection storage.
    /// Nil while disconnected, so every agent command is disabled (D-061),
    /// and while this window's sidebar selects a terminal row (B-057).
    var selectedLeoRow: LeoAgentRow? {
        guard leoSession?.terminals.selection == nil else { return nil }
        return leoRuntime?.model.actionableSelection
    }

    /// Availability of the agent-scoped commands (Start, Stop, Rename, ...)
    /// for the current window/selection, reusing `LeoRowActionAvailability`
    /// -- the same status-gating logic the sidebar's row context menu uses
    /// -- so the menu bar and the context menu never disagree.
    var selectedLeoAgentContext: LeoMenuCommands.AgentContext {
        let row = selectedLeoRow
        let availability = row.map { row in
            LeoRowActionAvailability(
                status: row.status,
                isPending: leoRuntime?.actions.pendingActions.contains(row.id) ?? false
            )
        }
        return LeoMenuCommands.AgentContext(hasLeoSession: leoSession != nil, availability: availability)
    }

    /// B-055: the window's one content area shows `tree` in place of what
    /// it showed; the sidebar, editor and browser panes are the window's
    /// and stay as they are. Returns the displaced tree, which the caller
    /// hides in the window's live pool or lets go (B-056).
    ///
    /// Assigned directly, not through `replaceSurfaceTree`: that registers
    /// an undo, and undoing a switch would resurrect surfaces whose tmux
    /// clients were let go. Focus moves without a `from:` so nothing keeps
    /// the displaced surfaces alive past this turn.
    @discardableResult
    func leoReplaceContent(
        with tree: SplitTree<Ghostty.SurfaceView>,
        focusing view: Ghostty.SurfaceView
    ) -> SplitTree<Ghostty.SurfaceView> {
        let displaced = surfaceTree
        if !tree.isEmpty { leoMarkFilled() }
        surfaceTree = tree
        focusedSurface = view
        Ghostty.moveFocus(to: view)
        return displaced
    }

    /// File ▸ Choose Agent… (⌘O): the agent palette, whose choice shows
    /// in this window's content area -- or fills its start screen (B-057
    /// moved it off ⌘T). A plain shell chosen there inherits the focused
    /// terminal's configuration, as ⌘T's does.
    @IBAction func chooseLeoAgent(_ sender: Any?) {
        guard let leoSession, let leoRuntime else { return }
        let inherited = focusedSurface?.surface.map {
            Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_TAB))
        }
        leoRuntime.routeNewSurface(surfaceTree.isEmpty ? .placeholder : .content, origin: leoSession.id, inheritedConfig: inherited)
    }

    @IBAction func toggleLeoSidebar(_ sender: Any?) {
        guard let leoSession else { return }
        // The menu item is disabled then; anything else calling this beeps too.
        guard leoSession.isSidebarVisible || !leoSession.showingSidebarSqueezesTerminal else {
            NSSound.beep()
            return
        }
        leoSession.setSidebarVisible(!leoSession.isSidebarVisible)
    }

    /// Agents ▸ Find Agent… (⌥⌘F; ⌘F is the terminal's Find).
    @IBAction func findLeoAgent(_ sender: Any?) {
        guard let leoSession else { return }
        guard leoSession.isSidebarVisible || !leoSession.showingSidebarSqueezesTerminal else {
            NSSound.beep()
            return
        }
        leoSession.requestSearchFocus()
    }

    @IBAction func startLeoDaemon(_ sender: Any?) {
        do {
            let path = try (NSApp.delegate as? AppDelegate)?.leoRuntime.resolveExecutablePath()
            guard let path else { return }
            let command = try LeoCommandLauncher.startDaemonCommand(executablePath: path)
            guard LeoCommandLauncher.openWindow(in: self, command: command) else {
                (NSApp.delegate as? AppDelegate)?.leoRuntime.model.setPanelError("Unable to open a terminal window")
                return
            }
        } catch {
            (NSApp.delegate as? AppDelegate)?.leoRuntime.model.setPanelError(error.localizedDescription)
        }
    }

    @IBAction func newLeoAgent(_ sender: Any?) {
        guard leoSession != nil, let runtime = (NSApp.delegate as? AppDelegate)?.leoRuntime else { return }
        let sheet = NSHostingController(rootView: SpawnAgentSheet(model: runtime.model, actions: runtime.actions) { row, disposition in
            guard let id = self.leoSession?.id else { return }
            runtime.model.attachRequested(row, id, disposition)
        })
        window?.contentViewController?.presentAsSheet(sheet)
    }

    func validateLeoSidebarMenuItem(_ item: NSMenuItem) -> Bool {
        let hasLeoSession = leoSession != nil
        item.title = LeoMenuCommands.sidebarToggleTitle(
            hasLeoSession: hasLeoSession,
            isSidebarVisible: leoSession?.isSidebarVisible ?? false
        )
        return LeoMenuCommands.canToggleSidebar(
            hasLeoSession: hasLeoSession,
            isSidebarVisible: leoSession?.isSidebarVisible ?? false,
            showingSqueezesTerminal: leoSession?.showingSidebarSqueezesTerminal ?? false)
    }

    func validateFindLeoAgentMenuItem(_ item: NSMenuItem) -> Bool {
        LeoMenuCommands.canFindAgent(
            hasLeoSession: leoSession != nil,
            isSidebarVisible: leoSession?.isSidebarVisible ?? false,
            showingSqueezesTerminal: leoSession?.showingSidebarSqueezesTerminal ?? false)
    }

    func validateNewLeoAgentMenuItem(_ item: NSMenuItem) -> Bool {
        LeoMenuCommands.canCreateAgent(hasLeoSession: leoSession != nil)
    }
}
