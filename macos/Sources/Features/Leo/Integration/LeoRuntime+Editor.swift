import AppKit
import GhosttyKit

extension LeoRuntime {
    /// Ghostty's open-URL action (a ⌘-clicked link or OSC 8 hyperlink).
    /// `file://` URLs and bare paths clicked in an agent's terminal open in
    /// that window's editor pane, on the agent's host; `false` leaves
    /// everything else -- web links, plain shells -- to Ghostty.
    func openLinkInEditor(_ url: String, isOSC8: Bool, from surface: Ghostty.SurfaceView) -> Bool {
        guard let identity = attachCoordinator.identity(forSurface: surface.id),
              let reference = LeoEditorLink.fileReference(inOpenURL: url, isOSC8: isOSC8),
              let controller = surface.window?.windowController as? TerminalController,
              let session = controller.leoSession else { return false }
        let agent = editorContext(for: identity)
        Task { await openInEditor(reference, for: agent, in: session, window: controller.window) }
        return true
    }

    /// Whose workspace a typed path is relative to in `controller`'s
    /// window: the agent in its focused terminal, else the sidebar's
    /// selection, else nobody (absolute paths on the selected host).
    func editorContext(in controller: TerminalController) -> LeoEditorAgentContext {
        if let surface = controller.focusedSurface, let identity = attachCoordinator.identity(forSurface: surface.id) {
            return editorContext(for: identity)
        }
        if let row = controller.selectedLeoRow {
            return LeoEditorAgentContext(host: row.host, name: row.name, workspace: row.workspace)
        }
        return LeoEditorAgentContext(host: hostSelection.selected, name: nil, workspace: nil)
    }

    /// Opens `text` for `agent` in `session`'s pane; failures get a sheet.
    /// A local folder still opens in Finder, as a ⌘-click did before.
    func openInEditor(_ text: String, for agent: LeoEditorAgentContext, in session: LeoWindowSession, window: NSWindow?) async {
        do {
            try await session.editor.open(link: text, for: agent)
        } catch LeoFileAccessError.isADirectory(let path) where agent.host == .local {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            LeoEditorAlerts.presentError(error, on: window)
        }
    }

    /// Quitting with unsaved editor edits asks about each window's first
    /// (Save / Don't Save / Cancel). `true` when it took over: the quit is
    /// retried once every one is resolved, and dropped on Cancel.
    func deferQuitForUnsavedEditors() -> Bool {
        let dirty = registry.sessions.filter { $0.editor.document?.isDirty == true }
        guard !dirty.isEmpty else { return false }
        Task {
            for session in dirty {
                registry.controller(for: session.id)?.window?.makeKeyAndOrderFront(nil)
                guard await session.editor.close() else { return }
            }
            NSApp.terminate(nil)
        }
        return true
    }

    /// The daemon's current row for the agent (its workspace may have been
    /// reported after the attach), falling back to what the attach knew.
    private func editorContext(for identity: LeoAgentIdentity) -> LeoEditorAgentContext {
        let row = model.snapshot.rows.first { $0.host == identity.host && $0.name == identity.name }
        return LeoEditorAgentContext(host: identity.host, name: identity.name, workspace: row?.workspace ?? identity.workspace)
    }
}

extension Ghostty.App {
    /// Leo: offers an open-URL action to the agent editor before Ghostty's
    /// own handling (see `LeoRuntime.openLinkInEditor`).
    static func leoOpenURLInEditor(target: ghostty_target_s, _ value: ghostty_action_open_url_s) -> Bool {
        guard Thread.isMainThread, target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return false }
        let view = Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let action = Ghostty.Action.OpenURL(c: value)
        return MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.leoRuntime.openLinkInEditor(action.url, isOSC8: action.kind == .osc8, from: view) ?? false
        }
    }
}
