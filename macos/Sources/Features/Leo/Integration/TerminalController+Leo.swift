import AppKit
import Combine
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
                isPending: leoRuntime?.actions.pendingActions.contains(row.id) ?? false,
                movedTo: row.movedTo
            )
        }
        let movesSupported = row.flatMap { row in leoRuntime?.model.features(for: row.host).contains(.agentMove) } ?? true
        return LeoMenuCommands.AgentContext(hasLeoSession: leoSession != nil, availability: availability, movesSupported: movesSupported)
    }

    /// B-055: the window's one content area shows `tree` in place of what
    /// it showed; the sidebar, editor and browser panes are the window's
    /// and stay as they are. Returns the displaced tree, which the caller
    /// hides in the window's live pool or lets go (B-056).
    ///
    /// Assigned directly, not through `replaceSurfaceTree`: that registers
    /// an undo, and undoing a switch would resurrect surfaces whose tmux
    /// clients were let go. Nor does the window's earlier undo cross it
    /// (`leoForgetContentUndo`, B-071). Focus moves without a `from:` so
    /// nothing keeps the displaced surfaces alive past this turn.
    @discardableResult
    func leoReplaceContent(
        with tree: SplitTree<Ghostty.SurfaceView>,
        focusing view: Ghostty.SurfaceView
    ) -> SplitTree<Ghostty.SurfaceView> {
        let displaced = surfaceTree
        if !tree.isEmpty { leoMarkFilled() }
        surfaceTree = tree
        leoForgetContentUndo()
        focusedSurface = view
        // Whether the terminal may take focus is asked when the move runs:
        // the row just selected may remember Chat, covering it.
        if let leoSession {
            leoSession.routeTerminalFocus { Ghostty.moveFocus(to: view, isAllowed: $0) }
        } else {
            Ghostty.moveFocus(to: view)
        }
        return displaced
    }

    /// B-071: undo doesn't cross a content swap or the start screen. What
    /// this window's undo holds -- ⌘D's "New Split", a split's "Close
    /// Terminal", their redos, its "New Window" -- replays by assigning a
    /// tree from before, which skips the host's retire: what the window
    /// shows then would be dropped without being kept (a busy shell killed
    /// without asking), and the replayed tree could show a row that is
    /// still kept hidden. So they are forgotten here; a split closed before
    /// the swap was confirmed at ⌘W and would expire after `undo-timeout`
    /// anyway. Other windows' undo is untouched.
    ///
    /// Known limit: all windows share one undo manager, and a cross-window
    /// Move Split is one undo group holding one action per window it
    /// touched -- `splitDidDrop`'s "Close Terminal" on the source and
    /// replace on the destination, or `ghosttySurfaceDragEndedNoTarget`'s
    /// replace on the source and "New Window" for the window it opens.
    /// This drops only the swapped controller's half; the other window's
    /// half stays (D-141), and that is not harmless: ⌘Z then replays a
    /// half-move, and once the redo expires it can free the moved
    /// surface's shell without asking (P2). That risk, and the moved
    /// surface's row and window ownership, are B-110's to fix.
    func leoForgetContentUndo() {
        undoManager?.removeAllActions(withTarget: self)
    }

    /// B-332: whether the window lists a Terminals row, so it saves its
    /// rows for restoring at launch. One listing none saves nothing.
    var leoHasRestorableTerminals: Bool { leoSession?.terminals.rows.isEmpty == false }

    /// B-332: the window's rows, a title or its selection changed. It is
    /// restorable while it lists a row (never in a test host), and what
    /// it saved is stale: AppKit saves it again later.
    func leoTerminalsDidChange() {
        guard let window else { return }
        let isRestorable = LeoTerminalWindowRestoration.isEnabled && leoHasRestorableTerminals
        if window.isRestorable != isRestorable { window.isRestorable = isRestorable }
        window.invalidateRestorableState()
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

    /// Puts the agent toolbar on an agent window and keeps its subtitle on
    /// the selected agent's `<cwd> · <harness>`. A window without decorations
    /// is a plain `TerminalWindow` and gets neither.
    func leoInstallAgentToolbar() {
        guard let window = window as? LeoAgentTerminalWindow, let leoSession, let leoRuntime else { return }
        window.leoToolbar.makeActivityView = { [model = leoRuntime.model, terminals = leoSession.terminals, actions = leoRuntime.actions] in
            let host = NSHostingView(rootView: LeoActivityCapsule(model: model, terminals: terminals, actions: actions))
            host.sizingOptions = []
            return host
        }
        let updateModel = (NSApp.delegate as? AppDelegate)?.updateViewModel
        window.leoToolbar.makeUpdateView = {
            guard let updateModel else { return NSView() }
            return NonDraggableHostingView(rootView: UpdatePill(model: updateModel))
        }
        let chat = leoRuntime.chat
        let toolbarMenu = LeoAgentToolbarMenu(
            mainMenu: { NSApp.mainMenu },
            messages: .init(
                knownTasks: { chat.timeline.knownTasks }, filter: { chat.timeline.taskFilter },
                hasAgent: { [weak self] in self?.selectedLeoRow != nil },
                select: { [weak self] in self?.leoShowMessages(forTask: $0) }))
        window.leoToolbar.moreMenu = toolbarMenu.menu
        window.leoToolbar.retainedMenu = toolbarMenu
        window.installToolbar(inset: leoSession.toolbarInset)
        window.leoToolbar.bind(sidebarVisible: leoSession.$isSidebarVisible)
        window.leoToolbar.bind(sideBySideChatWidth: leoSession.$sideBySideChatWidth)
        window.leoToolbar.bind(surfaceZoomed: window.surfaceZoomedPublisher)
        if let updateModel {
            window.leoToolbar.bind(updateVisible: updateModel.$state.map { !$0.isHidden })
        }
        window.leoToolbar.onSubtitleVisibilityChange = { [weak self] in self?.leoRefreshSubtitle() }
        leoSession.onSplitViewReady = { [weak window] in window?.leoToolbar.attach(splitView: $0) }
        // `objectWillChange` fires before the change lands: read next turn.
        leoSelectionChanges
            .sink { [weak self] in self?.leoRefreshSubtitle() }
            .store(in: &window.chromeSubscriptions)
        leoRefreshSubtitle()
    }

    /// "Show Messages ▸" in the toolbar: filters the chat to `task` (nil: all
    /// messages) and brings Chat up when only the terminal shows, since the
    /// filter has no effect out of sight.
    func leoShowMessages(forTask task: String?) {
        guard let leoRuntime, let leoSession, let row = selectedLeoRow else { return }
        let chat = leoRuntime.chat
        leoSession.showMessages(of: row.id) { Task { await chat.setTaskFilter(task) } }
    }

    /// Fires (next turn, after the change landed) whenever the shown row or
    /// the rows' data change.
    private var leoSelectionChanges: AnyPublisher<Void, Never> {
        guard let leoRuntime, let leoSession else { return Empty().eraseToAnyPublisher() }
        return leoRuntime.model.objectWillChange.map { _ in () }
            .merge(with: leoSession.terminals.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// The selected agent's `<cwd> · <harness>`; empty for a terminal row,
    /// the start screen, or while disconnected.
    func leoRefreshSubtitle() {
        guard let window = window as? LeoAgentTerminalWindow, let leoRuntime else { return }
        let text = selectedLeoRow.map { row in
            LeoAgentWindowSubtitle.text(
                workspace: row.workspace, harness: row.harness, host: row.host,
                localHome: NSHomeDirectory(), remoteUser: leoRuntime.machines.configuration(for: row.host)?.user)
        }.flatMap { window.leoToolbar.showsSubtitle ? $0 : nil } ?? ""
        if window.subtitle != text { window.subtitle = text }
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
        let sheetView = SpawnAgentSheet(model: runtime.model, actions: runtime.actions) { row, disposition in
            guard let id = self.leoSession?.id else { return }
            runtime.model.attachRequested(row, id, disposition)
        }
        let sheet = NSHostingController(rootView: sheetView.leoSheetClose(in: window))
        window?.presentLeoSheet(sheet)
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
