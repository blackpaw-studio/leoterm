import AppKit

/// B-013 on the runtime: a surfaced file the user asked for opens in the
/// agent row's own editor pane (B-004, B-274) in the window the user is
/// in, and the row is shown there; on the agent's host
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
        let editor = pane(for: row, in: session).editor
        let target = LeoSurfacedFileOpener.Target(
            stat: { try await editor.stat($0) },
            open: { [weak self, weak session] fileID, line, isStillWanted in
                let outcome = try await editor.open(fileID, line: line, readDeadline: .surfacedOpen, isStillWanted: isStillWanted)
                if outcome != .cancelled, let self, let session { await showRow(row, in: session) }
                return outcome
            },
            reportError: { [weak controller] in LeoEditorAlerts.presentError($0, on: controller?.window) },
            isStillWanted: stillWanted
        )
        Task { await surfacedFileOpener.open(file, host: row.host, in: target) }
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
