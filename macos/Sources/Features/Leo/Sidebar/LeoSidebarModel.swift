import Combine
import Foundation

@MainActor final class LeoSidebarModel: ObservableObject {
    @Published private(set) var snapshot: LeoSidebarSnapshot
    @Published var query = ""
    @Published var selection: LeoAgentRow.ID?
    @Published private(set) var rowErrors: [LeoAgentRow.ID: String] = [:]
    @Published private(set) var rowErrorCodes: [LeoAgentRow.ID: String] = [:]
    @Published private(set) var panelError: String?
    /// Focused attach row and live attach counts (see `+AttachLinks`).
    @Published var attachLinks = LeoAttachLinkState.empty
    /// The attach host's latest yielded focus report (see
    /// `LeoAttachCoordinator.latestFocusReport`).
    var latestFocusReport: () -> Int = { 0 }
    /// Focus reports up to this one were already in flight when the user
    /// last selected a row, so they never move the selection.
    var userSelectionFence: Int?
    var attachRequested: (LeoAgentRow, LeoWindowID, AttachDisposition) -> Void = { _, _, _ in }
    /// Brings the row's existing attach tab forward (no new attach).
    var focusExistingRequested: (LeoAgentRow) -> Void = { _ in }
    var startDaemonRequested: () -> Void = {}
    var retryRequested: () -> Void = {}
    var sshRequested: (String) -> Void = { _ in }
    /// Fired when the Dock attention count changes (AppDelegate's badge writer).
    var attentionCountChanged: (Int) -> Void = { _ in }

    /// Sort order, pins and collapsed sections (B-010), saved to
    /// `preferencesStore` on every change.
    @Published private(set) var preferences: LeoSidebarPreferences
    private let preferencesStore: any LeoSidebarPreferencesStore

    init(
        snapshot: LeoSidebarSnapshot = .init(rows: [], connectivity: .loading, generation: 0),
        preferencesStore: any LeoSidebarPreferencesStore = LeoInMemorySidebarPreferencesStore()
    ) {
        self.snapshot = snapshot
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
    }

    /// The host whose collapsed sections apply: the feed's rows are all
    /// from the selected host.
    private var rowsHost: LeoHostID { snapshot.rows.first?.host ?? .local }

    var sections: [LeoSidebarSection] {
        LeoSidebarLayout.sections(rows: snapshot.rows, query: query, preferences: preferences, host: rowsHost)
    }

    var visibleRows: [LeoAgentRow] {
        LeoSidebarLayout.visibleRows(rows: snapshot.rows, query: query, preferences: preferences, host: rowsHost)
    }

    /// Every row in unfiltered display order, collapsed ones included.
    var orderedRows: [LeoAgentRow] { LeoSidebarLayout.orderedRows(snapshot.rows, preferences: preferences) }

    func setSortOrder(_ order: LeoSidebarSortOrder) { update(preferences.with(sortOrder: order)) }

    func isPinned(_ id: LeoAgentRow.ID) -> Bool { preferences.pinned.contains(id) }

    func togglePin(_ id: LeoAgentRow.ID) { update(preferences.togglingPin(id)) }

    func isCollapsed(_ sectionID: String) -> Bool { preferences.isCollapsed(sectionID, host: rowsHost) }

    func toggleCollapsed(_ sectionID: String) {
        update(preferences.setting(sectionID, collapsed: !isCollapsed(sectionID), host: rowsHost))
    }

    /// Expands the section holding `id`, so a row something jumps to is
    /// on screen.
    func reveal(_ id: LeoAgentRow.ID) {
        guard let row = snapshot.rows.first(where: { $0.id == id }) else { return }
        let sectionID = LeoSidebarLayout.sectionID(of: row, preferences: preferences)
        guard isCollapsed(sectionID) else { return }
        update(preferences.setting(sectionID, collapsed: false, host: row.host))
    }

    private func update(_ updated: LeoSidebarPreferences) {
        guard updated != preferences else { return }
        preferences = updated
        preferencesStore.save(updated)
    }

    func receive(_ value: LeoSidebarSnapshot) {
        guard value.generation >= snapshot.generation else { return }
        let previousAttentionCount = snapshot.attentionCount
        let previousRows = snapshot.rows
        snapshot = value
        defer { reapplyFocusedRow(previousRows: previousRows) }
        if value.attentionCount != previousAttentionCount { attentionCountChanged(value.attentionCount) }
        if value.listRefreshSucceeded {
            rowErrors = [:]
            rowErrorCodes = [:]
        }
        guard let selection, !value.rows.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
    }

    func retry() { retryRequested() }

    /// Rows are shown but inert while disconnected (D-061).
    var isDisconnected: Bool { snapshot.connectivity.isDisconnected }

    var selectedRow: LeoAgentRow? { selection.flatMap { id in snapshot.rows.first { $0.id == id } } }

    /// The selected row, when agent commands may act on it: never while
    /// disconnected.
    var actionableSelection: LeoAgentRow? { isDisconnected ? nil : selectedRow }

    /// Every sidebar attach goes through here; a no-op while disconnected.
    func requestAttach(_ row: LeoAgentRow, from windowID: LeoWindowID, disposition: AttachDisposition) {
        guard !isDisconnected else { return }
        attachRequested(row, windowID, disposition)
    }
    func setRowError(_ message: String, code: String? = nil, for id: LeoAgentRow.ID) {
        rowErrors[id] = message
        rowErrorCodes[id] = code
    }

    func setRowError(_ id: LeoAgentRow.ID, message: String) {
        setRowError(message, for: id)
    }

    func setPanelError(_ message: String) { panelError = message }
}
