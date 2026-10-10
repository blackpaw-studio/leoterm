import AppKit
import GhosttyKit

/// B-177: what a terminal row's context menu does to its shell, shown or
/// hidden. Agent rows are the daemon's to name and close, so nothing here
/// reaches them.
extension GhosttyAttachContentHost {
    /// Rename…: titles the row's shell `name`, as Change Terminal Title…
    /// does. The title sticks over the terminal's own until an empty name
    /// restores it, and it is the one title the row, the window and a
    /// close confirm read. A hidden shell is retitled where it is; nothing
    /// on screen changes.
    func renameTerminal(_ handle: AttachmentHandle, to name: String) {
        terminalRowSurface(handle)?.1.leoSetUserTitle(name)
    }

    /// The terminal's own title for the row, under any name it was given:
    /// what Rename… restores when left blank.
    func liveTitle(of handle: AttachmentHandle) -> String? {
        terminalRowSurface(handle)?.1.leoLiveTitle
    }

    /// Close on the row's menu, asking first as ⌘W does when a process is
    /// running. Shown, it is ⌘W's own path: Ghostty decides whether to ask
    /// and names the pane (`leoCloseTerminalRow`, or a split's close beside
    /// another pane). Hidden, nothing on screen can ask for it, so the
    /// same "Close …?" confirm is put up here; with nothing running it
    /// closes straight away. Cancelled, or another alert already up on the
    /// window, it stays.
    /// Its pane's unsaved edits are asked about first (B-274).
    func closeTerminalFromMenu(_ handle: AttachmentHandle) async {
        guard let (controller, surface) = terminalRowSurface(handle) else { return }
        if let panes = controller.leoSession?.panes, panes.existingPane(for: .terminal(handle.surfaceID))?.hasUnsavedEdits == true {
            guard await panes.close(.terminal(handle.surfaceID)), terminalRowSurface(handle) != nil else { return }
        }
        if controller.surfaceTree.contains(surface) {
            guard let ghosttySurface = surface.surface else { return }
            return controller.ghostty.requestClose(surface: ghosttySurface)
        }
        if surface.needsConfirmQuit {
            let response = await controller.confirmCloseAsync(
                messageText: LeoCloseConfirmation.messageText(closing: [surface.leoPaneName]),
                informativeText: LeoCloseConfirmation.rowInformativeText
            )
            guard let response, [.alertFirstButtonReturn, .OK].contains(response) else { return }
        }
        controller.leoSession?.terminals.closeRequested(handle.surfaceID)
    }

    /// What a split beside the row's shell starts from, as ⌘D's: the
    /// shell's working directory and the like.
    func splitConfiguration(for handle: AttachmentHandle) -> Ghostty.SurfaceConfiguration? {
        guard let surface = terminalRowSurface(handle)?.1.surface else { return nil }
        return Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT))
    }
}
