import AppKit

/// B-013 on the runtime: a surfaced file opens in the editor pane (B-004)
/// of the window the user is in, on the agent's host through that window's
/// file access (local FS or SFTP), at its line if it has one --
/// automatically only after `LeoSurfacedFileOpener`'s checks. A manual
/// open's missing or unreadable file gets the editor's own error sheet.
extension LeoRuntime {
    func openSurfacedFile(_ file: LeoSurfacedFile, for row: LeoAgentRow, mode: LeoSurfacedOpenMode) {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.preferredParent
        guard let controller, let session = controller.leoSession else {
            if mode == .manual { model.setRowError("No terminal window available", for: row.id) }
            return
        }
        let editor = session.editor
        let paneOpens = editor.openRequests
        let stillWanted = model.surfacedAutoOpenGuard(for: file, row: row)
        let target = LeoSurfacedFileOpener.Target(
            stat: { try await editor.stat($0) },
            open: { fileID, line in
                try await editor.open(fileID, line: line, readDeadline: mode == .automatic ? .automaticOpen : nil)
            },
            reportError: { [weak controller] in LeoEditorAlerts.presentError($0, on: controller?.window) },
            isStillWanted: { stillWanted() && editor.openRequests == paneOpens }
        )
        Task { await surfacedFileOpener.open(file, host: row.host, mode: mode, in: target) }
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
