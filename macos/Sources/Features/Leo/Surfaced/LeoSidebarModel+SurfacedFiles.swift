import Foundation

/// B-013 routing: a surfaced file is *pending* until opened. One that
/// arrives while its agent's attach tab is focused opens at once; the rest
/// wait, and the newest pending one opens when the user next focuses that
/// agent's tab or clicks its row. Opening always marks seen. Rows only
/// ever carry files of their own incarnation (`LeoSurfacedFileIndex`), and
/// nothing opens by itself while disconnected.
extension LeoSidebarModel {
    /// This row's unseen surfaced files, newest last.
    func pendingSurfacedFiles(for row: LeoAgentRow) -> [LeoSurfacedFile] {
        row.surfacedFiles.filter { !surfacedSeen.isSeen($0.id, host: row.host) }
    }

    /// A live `file_surfaced` for `host` (already accepted by the feed).
    /// Opens when its incarnation's row is the focused agent; otherwise it
    /// stays pending.
    func fileSurfaced(_ file: LeoSurfacedFile, host: LeoHostID) {
        guard !isDisconnected,
              let row = snapshot.rows.first(where: { $0.host == host && $0.name == file.agent && $0.startedAt == file.startedAt }),
              row.id == focusedAgent, !surfacedSeen.isSeen(file.id, host: host) else { return }
        openSurfacedFile(file, for: row)
    }

    /// Focus moved to `id`'s attach tab (or off every one): the newest
    /// pending file of a newly focused agent opens.
    func focusedAgentChanged(_ id: LeoAgentRow.ID?) {
        guard id != focusedAgent else { return }
        focusedAgent = id
        let clickOpened = surfacedOpenedByClick
        surfacedOpenedByClick = nil
        guard let id, id != clickOpened, let row = snapshot.rows.first(where: { $0.id == id }) else { return }
        openNewestPendingSurfacedFile(for: row)
    }

    /// A click on `row` (see `rowClicked`). A row whose live attach the
    /// click brings forward leaves the open to that focus change, so it
    /// happens once; so does a double-click's second click, or its attach.
    func surfacedFilesRowClicked(_ row: LeoAgentRow, focusesExisting: Bool) {
        guard !focusesExisting || focusedAgent == row.id, surfacedOpenedByClick != row.id else { return }
        guard openNewestPendingSurfacedFile(for: row), focusedAgent != row.id else { return }
        surfacedOpenedByClick = row.id
    }

    /// Marks `file` seen and asks for it to open.
    func openSurfacedFile(_ file: LeoSurfacedFile, for row: LeoAgentRow) {
        let updated = surfacedSeen.markingSeen(file.id, host: row.host)
        if updated != surfacedSeen {
            surfacedSeen = updated
            surfacedSeenStore.save(updated)
        }
        surfacedFileOpenRequested(file, row)
    }

    /// Agents ▸ Open Surfaced File: the newest pending file, else the
    /// newest one (to reopen it). `false` when the row has none.
    @discardableResult
    func openNewestSurfacedFile(for row: LeoAgentRow) -> Bool {
        guard let file = pendingSurfacedFiles(for: row).last ?? row.surfacedFiles.last else { return false }
        openSurfacedFile(file, for: row)
        return true
    }

    @discardableResult
    private func openNewestPendingSurfacedFile(for row: LeoAgentRow) -> Bool {
        guard !isDisconnected, let file = pendingSurfacedFiles(for: row).last else { return false }
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
