import Foundation

/// The incarnation an agent's live attach tabs show. Tabs don't carry
/// `started_at`, so it's the row's when the agent's first tab appears (or,
/// tabs appearing before the list, the row's first). Once the row reports
/// another one while any of those tabs lives -- a restart under the same
/// name -- it's unknown until every tab of the agent is gone; a tab
/// attached meanwhile doesn't settle it (which tab shows what is unknown).
enum LeoTabIncarnation: Equatable, Sendable {
    case awaitingRow
    case known(String)
    case unknown
}

/// B-013 routing: a surfaced file is *pending* until opened. One that
/// arrives while its agent's attach tab is focused opens at once; the rest
/// wait, and the newest pending one opens when the user next focuses that
/// agent's tab or clicks its row. Whenever a tab is involved, it must show
/// the file's incarnation (`LeoTabIncarnation`); otherwise the file stays
/// badged, reachable from the menus. Opening marks seen once the pane
/// shows it (`LeoSurfacedFileOpener`). Rows only ever carry files of their
/// own incarnation (`LeoSurfacedFileIndex`), and nothing opens by itself
/// while disconnected.
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
              row.id == focusedAgent, tabsShow(row),
              !surfacedSeen.isSeen(file.id, host: host) else { return }
        surfacedFileOpenRequested(file, row, .automatic)
    }

    /// Called as each snapshot or attach link state lands.
    func trackTabIncarnations() {
        let live = attachLinks.tabCounts.filter { $0.value > 0 }.keys
        tabIncarnations = Dictionary(uniqueKeysWithValues: live.map { id in
            let row = snapshot.rows.first { $0.id == id }
            return (id, Self.tabIncarnation(tabIncarnations[id] ?? .awaitingRow, row: row))
        })
        openAwaitedFocus()
    }

    /// The focus open deferred by `focusedAgentChanged`, once the tab's
    /// incarnation is settled either way (unknown or another one: dropped).
    private func openAwaitedFocus() {
        guard let id = focusOpenAwaitingTab else { return }
        guard id == focusedAgent else {
            focusOpenAwaitingTab = nil
            return
        }
        guard let row = snapshot.rows.first(where: { $0.id == id }),
              let incarnation = tabIncarnations[id], incarnation != .awaitingRow else { return }
        focusOpenAwaitingTab = nil
        guard tabsShow(row) else { return }
        openNewestPendingSurfacedFile(for: row)
    }

    private static func tabIncarnation(_ current: LeoTabIncarnation, row: LeoAgentRow?) -> LeoTabIncarnation {
        guard let row else { return current }
        switch current {
        case .awaitingRow: return row.startedAt.map { .known($0) } ?? .unknown
        case .known(let startedAt) where startedAt != row.startedAt: return .unknown
        case .known, .unknown: return current
        }
    }

    /// Whether `row`'s tabs show its current incarnation (the one its
    /// surfaced files belong to).
    private func tabsShow(_ row: LeoAgentRow) -> Bool {
        guard let startedAt = row.startedAt else { return false }
        return tabIncarnations[row.id] == .known(startedAt)
    }

    /// Focus moved to `id`'s attach tab (or off every one): the newest
    /// pending file of a newly focused agent opens.
    func focusedAgentChanged(_ id: LeoAgentRow.ID?) {
        guard id != focusedAgent else { return }
        focusedAgent = id
        focusOpenAwaitingTab = nil
        let clickOpened = surfacedOpenedByClick
        surfacedOpenedByClick = nil
        guard let id, id != clickOpened else { return }
        guard let row = snapshot.rows.first(where: { $0.id == id }), tabIncarnations[id].map({ $0 != .awaitingRow }) == true else {
            focusOpenAwaitingTab = id
            return
        }
        guard tabsShow(row) else { return }
        openNewestPendingSurfacedFile(for: row)
    }

    /// A click on `row` (see `rowClicked`). A row whose live attach the
    /// click brings forward leaves the open to that focus change, so it
    /// happens once; so does a double-click's second click, or its attach.
    func surfacedFilesRowClicked(_ row: LeoAgentRow, focusesExisting: Bool) {
        guard !focusesExisting || (focusedAgent == row.id && tabsShow(row)), surfacedOpenedByClick != row.id else { return }
        guard openNewestPendingSurfacedFile(for: row), focusedAgent != row.id else { return }
        surfacedOpenedByClick = row.id
    }

    /// The user named `file` (a menu).
    func openSurfacedFile(_ file: LeoSurfacedFile, for row: LeoAgentRow) {
        surfacedFileOpenRequested(file, row, .manual)
    }

    /// Called by the opener once the pane shows `file`; until then it
    /// keeps its badge.
    func markSurfacedFileSeen(_ file: LeoSurfacedFile, host: LeoHostID) {
        let updated = surfacedSeen.markingSeen(file.id, host: host)
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

    @discardableResult
    private func openNewestPendingSurfacedFile(for row: LeoAgentRow) -> Bool {
        guard !isDisconnected, let file = pendingSurfacedFiles(for: row).last else { return false }
        surfacedFileOpenRequested(file, row, .automatic)
        return true
    }
}

extension LeoMenuCommands {
    /// Agents ▸ Open Surfaced File (⌥⌘O): the selected row has any.
    static func canOpenSurfacedFile(hasLeoSession: Bool, selected: LeoAgentRow?) -> Bool {
        hasLeoSession && !(selected?.surfacedFiles.isEmpty ?? true)
    }
}
