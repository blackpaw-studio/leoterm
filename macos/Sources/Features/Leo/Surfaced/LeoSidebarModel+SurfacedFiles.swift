import Foundation

/// B-013 routing: a surfaced file is *pending* (badged) until the user
/// opens it with Agents ▸ Open Surfaced File (⌥⌘O) or a row's Surfaced
/// Files ▸ item. Nothing opens by itself -- not on arrival, focus or a row
/// click (D-088). Opening marks seen once the pane shows it
/// (`LeoSurfacedFileOpener`). Rows only ever carry files of their own
/// incarnation (`LeoSurfacedFileIndex`).
extension LeoSidebarModel {
    /// This row's unseen surfaced files, newest last.
    func pendingSurfacedFiles(for row: LeoAgentRow) -> [LeoSurfacedFile] {
        row.surfacedFiles.filter { !surfacedSeen.isSeen($0, host: row.host) }
    }

    /// The user named `file` (a menu). Nothing happens while disconnected
    /// or once the row no longer shows the file's incarnation.
    func openSurfacedFile(_ file: LeoSurfacedFile, for row: LeoAgentRow) {
        let stillWanted = surfacedOpenGuard(for: file, row: row)
        guard stillWanted() else { return }
        surfacedFileOpenRequested(file, row, stillWanted)
    }

    /// Whether an open of `file` may still go ahead: connected, and `row`
    /// still shows the file's incarnation (the agent didn't restart under
    /// the same name). Re-checked by the opener after its stat.
    func surfacedOpenGuard(for file: LeoSurfacedFile, row: LeoAgentRow) -> @MainActor () -> Bool {
        { [weak self] in
            guard let self, !isDisconnected else { return false }
            return snapshot.rows.first { $0.id == row.id }?.startedAt == file.startedAt
        }
    }

    /// Called by the opener once the pane shows `file`; until then it
    /// keeps its badge.
    func markSurfacedFileSeen(_ file: LeoSurfacedFile, host: LeoHostID) {
        let updated = surfacedSeen.markingSeen(file, host: host)
        guard updated != surfacedSeen else { return }
        surfacedSeen = updated
        surfacedSeenStore.save(updated)
    }

    /// Agents ▸ Open Surfaced File: the newest pending file, else the
    /// newest one (to reopen it). `false` when the row has none.
    @discardableResult
    func openNewestSurfacedFile(for row: LeoAgentRow) -> Bool {
        guard let file = pendingSurfacedFiles(for: row).last ?? row.surfacedFiles.last else { return false }
        openSurfacedFile(file, for: row)
        return true
    }
}

extension LeoMenuCommands {
    /// Agents ▸ Open Surfaced File (⌥⌘O): the selected row has any.
    static func canOpenSurfacedFile(hasLeoSession: Bool, selected: LeoAgentRow?) -> Bool {
        hasLeoSession && !(selected?.surfacedFiles.isEmpty ?? true)
    }
}
