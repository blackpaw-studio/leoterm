import Foundation

/// B-013 routing: a surfaced file is *pending* (badged) until it's seen.
/// B-273 (superseding D-088's no-auto-open): a live file opens by itself
/// as a tab in its agent's own pane, in the background, and is seen once
/// that agent's row is on screen in a visible window. Agents ▸ Open
/// Surfaced File (⌥⌘O) or a row's Surfaced Files ▸ item still opens one by
/// hand, showing the row, and marks it seen once the pane shows it
/// (`LeoSurfacedFileOpener`). Focus or a row click never opens one. Rows
/// only ever carry files of their own incarnation (`LeoSurfacedFileIndex`).
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

    /// B-273: a live file just surfaced on `host` (the feed's report): it
    /// opens in the background when connected, not yet seen, and a row on
    /// `host` shows its incarnation.
    func fileSurfaced(_ file: LeoSurfacedFile, host: LeoHostID) {
        guard !isDisconnected, !surfacedSeen.isSeen(file, host: host),
              let row = snapshot.rows.first(where: { $0.host == host && $0.name == file.agent && $0.startedAt == file.startedAt })
        else { return }
        surfacedFileAutoOpenRequested(file, row, surfacedOpenGuard(for: file, row: row))
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
