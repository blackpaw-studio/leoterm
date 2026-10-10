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
        // The raw selection, not the agent-command one: a local agent's
        // files are still there while its daemon is disconnected.
        if let row = model.selectedRow {
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
    /// (Save / Don't Save / Cancel); see `LeoUnsavedEditorsGate.deferQuit`.
    /// nil when there are none; otherwise `applicationShouldTerminate`'s
    /// answer. A system quit's deferred answer goes to `reply` (the app's
    /// `NSApp.reply(toApplicationShouldTerminate:)`, which marks the
    /// instance lock first on a yes).
    func deferQuitForUnsavedEditors(isSystemQuit: Bool, reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply? {
        unsavedEditors.deferQuit(
            of: registry.sessions.flatMap(editorEntries(for:)), isSystemQuit: isSystemQuit,
            reply: reply, retry: { NSApp.terminate(nil) }
        )
    }

    /// Ghostty's quit review closes windows itself -- no close path runs --
    /// and its sheets leave other windows editable. Before it closes
    /// `windows` (or, for nil, before the quit goes ahead), their editors'
    /// unsaved edits are asked about. `false`: stop the quit.
    func resolveUnsavedEdits(in windows: [NSWindow]? = nil) async -> Bool {
        let sessions = registry.sessions.filter { session in
            windows?.contains { $0 === session.window } ?? true
        }
        return await unsavedEditors.resolve(sessions.flatMap(editorEntries(for:)))
    }

    /// `session`'s editors for the gate, one per row's pane (B-274), the
    /// one on screen first: its window, for sheets about them, brought
    /// forward (and its tab selected) before one. A pane off screen names
    /// its row in its prompt.
    func editorEntries(for session: LeoWindowSession) -> [LeoUnsavedEditorsGate.Entry] {
        let id = session.id
        let bringForward: @MainActor () -> Void = { [weak self] in
            guard let window = self?.registry.controller(for: id)?.window else { return }
            window.tabGroup?.selectedWindow = window
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return session.panes.allEditors.map { editor in
            LeoUnsavedEditorsGate.Entry(editor: editor, window: { [weak session] in session?.window }, bringForward: bringForward)
        }
    }

    /// B-274: where Browse Files and Open Surfaced File on an agent row
    /// land (see `LeoRowPaneRouter`): shown as a click shows it, then in
    /// the pane of the window showing it.
    var rowPaneRouter: LeoRowPaneRouter {
        LeoRowPaneRouter(
            show: { [weak self] identity, origin in
                guard let self else { return nil }
                let request = LeoSurfaceRequest(origin: origin, disposition: .content)
                guard case .success(let handle) = await attachCoordinator.attach(identity: identity, request: request) else { return nil }
                return handle.windowID
            },
            session: { [weak self] in self?.registry.session(for: $0) }
        )
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
