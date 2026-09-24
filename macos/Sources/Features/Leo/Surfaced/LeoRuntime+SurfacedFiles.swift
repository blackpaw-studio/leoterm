import AppKit

/// B-013 on the runtime: a surfaced file opens in the editor pane (B-004)
/// of the window the user is in, on the agent's host through that window's
/// file access (local FS or SFTP), at its line if it has one. A missing or
/// unreadable file gets the editor's own error sheet.
extension LeoRuntime {
    func openSurfacedFile(_ file: LeoSurfacedFile, for row: LeoAgentRow) {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.preferredParent
        guard let controller, let session = controller.leoSession else {
            model.setRowError("No terminal window available", for: row.id)
            return
        }
        let fileID = LeoEditorFileID(host: row.host, path: file.absPath)
        Task { [weak controller] in
            do {
                try await session.editor.open(fileID, line: file.line)
            } catch {
                LeoEditorAlerts.presentError(error, on: controller?.window)
            }
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
