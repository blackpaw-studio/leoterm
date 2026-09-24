import AppKit
import SwiftUI

extension TerminalController {
    /// The Leo runtime singleton, when the app delegate has one installed.
    var leoRuntime: LeoRuntime? { (NSApp.delegate as? AppDelegate)?.leoRuntime }

    /// The sidebar row currently selected in this window's Leo runtime, if
    /// any. Menu commands that act "on the current sidebar selection" read
    /// this rather than duplicating `LeoSidebarModel`'s selection storage.
    /// Nil while disconnected, so every agent command is disabled (D-061).
    var selectedLeoRow: LeoAgentRow? { leoRuntime?.model.actionableSelection }

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

    @IBAction func toggleLeoSidebar(_ sender: Any?) {
        guard let leoSession else { return }
        // The menu item is disabled then; anything else calling this beeps too.
        guard leoSession.isSidebarVisible || !leoSession.showingSidebarSqueezesTerminal else {
            NSSound.beep()
            return
        }
        leoSession.setSidebarVisible(!leoSession.isSidebarVisible)
    }

    @IBAction func startLeoDaemon(_ sender: Any?) {
        do {
            let path = try (NSApp.delegate as? AppDelegate)?.leoRuntime.resolveExecutablePath()
            guard let path else { return }
            let command = try LeoCommandLauncher.startDaemonCommand(executablePath: path)
            guard LeoCommandLauncher.openTab(in: self, command: command) else {
                (NSApp.delegate as? AppDelegate)?.leoRuntime.model.setPanelError("Unable to open a terminal tab")
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

    func validateNewLeoAgentMenuItem(_ item: NSMenuItem) -> Bool {
        LeoMenuCommands.canCreateAgent(hasLeoSession: leoSession != nil)
    }
}
