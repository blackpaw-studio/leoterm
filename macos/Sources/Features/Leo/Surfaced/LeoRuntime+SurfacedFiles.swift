import AppKit

/// B-013 on the runtime: a surfaced file the user asked for opens as a tab
/// in the agent row's own editor pane (B-004, B-274, B-273), in the window that shows
/// the row once it's shown from the one the user is in (`LeoRowPaneRouter`);
/// on the agent's host
/// through that window's file access (local FS or SFTP), at its line if it
/// has one, after `LeoSurfacedFileOpener`'s checks. A missing or unreadable
/// file gets the editor's error sheet.
extension LeoRuntime {
    func openSurfacedFile(_ file: LeoSurfacedFile, for row: LeoAgentRow, stillWanted: @escaping @MainActor () -> Bool) {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.preferredParent
        guard let controller, let session = controller.leoSession else {
            model.setRowError("No terminal window available", for: row.id)
            return
        }
        let router = rowPaneRouter
        Task { [weak self] in
            guard let self, let (destination, pane) = await router.pane(for: row, from: session) else { return }
            let editor = pane.tabs
            let target = LeoSurfacedFileOpener.Target(
                stat: { try await editor.stat($0) },
                open: { fileID, line, isStillWanted in
                    try await editor.open(fileID, line: line, readDeadline: .surfacedOpen, isStillWanted: isStillWanted)
                },
                reportError: { [weak destination] in LeoEditorAlerts.presentError($0, on: destination?.window) },
                isStillWanted: stillWanted
            )
            await surfacedFileOpener.open(file, host: row.host, in: target)
        }
    }

    /// B-273: a file an agent just surfaced opens in that agent's own pane
    /// in the background (see `LeoSurfacedAutoOpen`): no focus, no
    /// navigation, no error sheet.
    func autoOpenSurfacedFile(_ file: LeoSurfacedFile, for row: LeoAgentRow, stillWanted: @escaping @MainActor () -> Bool) {
        let autoOpen = LeoSurfacedAutoOpen(
            sessions: { [weak self] in
                guard let self else { return [] }
                let key = (NSApp.keyWindow?.windowController as? TerminalController)?.leoSession
                return (key.map { [$0] } ?? []) + registry.sessions.filter { $0 !== key }
            },
            fallback: { ((NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.preferredParent)?.leoSession },
            liveWindow: { [weak self] in self?.attachCoordinator.liveWindow(of: $0) },
            opener: surfacedFileOpener
        )
        Task { await autoOpen.open(file, for: row, stillWanted: stillWanted) }
    }

    /// The selected row's newest pending (else newest) surfaced file:
    /// Agents ▸ Open Surfaced File.
    func openSelectedSurfacedFile() {
        guard let row = model.actionableSelection else { return }
        model.openNewestSurfacedFile(for: row)
    }
}

extension TerminalController {
    /// Agents ▸ Open Surfaced File (⌥⌘O).
    @IBAction func openLeoSurfacedFile(_ sender: Any?) {
        leoRuntime?.openSelectedSurfacedFile()
    }

    func validateLeoOpenSurfacedFileMenuItem(_ item: NSMenuItem) -> Bool {
        LeoMenuCommands.canOpenSurfacedFile(hasLeoSession: leoSession != nil, selected: selectedLeoRow)
    }
}
