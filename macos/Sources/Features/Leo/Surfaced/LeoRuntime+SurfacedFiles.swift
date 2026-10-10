import AppKit

/// B-013 on the runtime: a surfaced file the user asked for opens in the
/// agent row's own editor pane (B-004, B-274), in the window that shows
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
