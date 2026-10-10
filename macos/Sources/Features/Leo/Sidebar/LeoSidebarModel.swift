import Combine
import Foundation

@MainActor final class LeoSidebarModel: ObservableObject {
    @Published private(set) var snapshot: LeoSidebarSnapshot
    @Published var query = ""
    @Published var selection: LeoAgentRow.ID? {
        // A dispatch selection rides on its parent agent: any other
        // selection ends it for good, so it can't revive later.
        didSet {
            guard let dispatch = dispatchSelection, dispatch.parent != selection else { return }
            dispatchSelection = nil
        }
    }
    /// The dispatch row the user selected (B-266); see `+Dispatches`.
    @Published var dispatchSelection: LeoDispatchSelection?
    /// Dispatch rows whose children the user collapsed, by id (B-266).
    @Published var collapsedDispatches: Set<LeoDispatchRef> = []
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
    /// Opens an attachable dispatch in a window (B-266).
    var dispatchAttachRequested: (LeoAgentIdentity, LeoWindowID, AttachDisposition) -> Void = { _, _, _ in }
    /// Brings forward the tmux window holding a dispatch's viewer pane on
    /// Leo's tmux server for that host (B-271); failures are reported on
    /// the parent agent's row.
    var dispatchPaneFocusRequested: (LeoHostID, String, LeoAgentRow.ID) -> Void = { _, _, _ in }
    /// Brings forward the window already showing the row's agent (no new
    /// attach). The window clicked in, if known, closes when it is an
    /// untouched start screen (B-050).
    var focusExistingRequested: (LeoAgentRow, LeoWindowID?) -> Void = { _, _ in }
    /// Starts an agent through the daemon; the completion says whether the
    /// daemon accepted it (B-049's start prompt).
    var startRequested: (LeoAgentRow, @escaping (Bool) -> Void) -> Void = { _, _ in }
    /// Open "Start <name>?" prompts, one per window at most (see
    /// `+StartPrompt`; only that extension changes them).
    @Published var startPrompts: [LeoWindowID: LeoStartPrompt] = [:]
    var startDaemonRequested: () -> Void = {}
    var retryRequested: () -> Void = {}
    var sshRequested: (String) -> Void = { _ in }
    /// Fired when the Dock attention count changes (AppDelegate's badge writer).
    var attentionCountChanged: (Int) -> Void = { _ in }

    /// Sort order, pins and collapsed sections (B-010), saved to
    /// `preferencesStore` on every change.
    @Published private(set) var preferences: LeoSidebarPreferences
    private let preferencesStore: any LeoSidebarPreferencesStore

    /// Surfaced-file ids already opened, per host (B-013); see
    /// `LeoSidebarModel+SurfacedFiles.swift`.
    @Published var surfacedSeen: LeoSurfacedFileLedger
    let surfacedSeenStore: any LeoSurfacedFileSeenStore
    /// Opens a surfaced file the user asked for in the editor; the
    /// closure re-checks the file's incarnation (`surfacedOpenGuard`).
    var surfacedFileOpenRequested: (LeoSurfacedFile, LeoAgentRow, @escaping @MainActor () -> Bool) -> Void = { _, _, _ in }
    /// B-273: opens a newly surfaced file in its agent's pane in the
    /// background; the closure re-checks the file's incarnation.
    var surfacedFileAutoOpenRequested: (LeoSurfacedFile, LeoAgentRow, @escaping @MainActor () -> Bool) -> Void = { _, _, _ in }

    init(
        snapshot: LeoSidebarSnapshot = .init(rows: [], connectivity: .loading, generation: 0),
        preferencesStore: any LeoSidebarPreferencesStore = LeoInMemorySidebarPreferencesStore(),
        surfacedSeenStore: any LeoSurfacedFileSeenStore = LeoInMemorySurfacedFileSeenStore()
    ) {
        self.snapshot = snapshot
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
        self.surfacedSeenStore = surfacedSeenStore
        surfacedSeen = surfacedSeenStore.load()
    }

    /// What the selected host's daemon advertised (B-262: `agent_control`).
    var daemonFeatures: LeoDaemonFeatures { snapshot.features }

    /// The same features, stamped with the host that advertised them.
    var hostFeatures: LeoHostFeatures { snapshot.advertised }

    /// The host whose collapsed sections apply: the feed's rows are all
    /// from the selected host.
    private var rowsHost: LeoHostID { snapshot.rows.first?.host ?? .local }

    var sections: [LeoSidebarSection] {
        LeoSidebarLayout.sections(rows: snapshot.rows, query: query, preferences: preferences, host: rowsHost)
    }

    var visibleRows: [LeoAgentRow] {
        LeoSidebarLayout.visibleRows(rows: snapshot.rows, query: query, preferences: preferences, host: rowsHost)
    }

    /// Only the filter can leave nothing to show: collapsed sections keep
    /// their headers, which are how they're expanded again.
    var showsNoMatches: Bool { !snapshot.rows.isEmpty && sections.isEmpty }

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
        #if DEBUG
        LeoLaunchTiming.mark("firstSnapshot", "connectivity=\(value.connectivity) rows=\(value.rows.count)")
        if !value.rows.isEmpty { LeoLaunchTiming.mark("firstRows", "rows=\(value.rows.count)") }
        #endif
        defer { reapplyFocusedRow(previousRows: previousRows) }
        if value.attentionCount != previousAttentionCount { attentionCountChanged(value.attentionCount) }
        if value.listRefreshSucceeded {
            rowErrors = [:]
            rowErrorCodes = [:]
        }
        resolveStartPrompts()
        reconcileDispatchSelection()
        pruneCollapsedDispatches()
        guard let selection, !value.rows.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
    }

    func retry() { retryRequested() }

    /// Rows are shown but inert while disconnected (D-061).
    var isDisconnected: Bool { snapshot.connectivity.isDisconnected }

    /// The live dispatches nested under `row` (B-257), depth first.
    func dispatchChildren(for row: LeoAgentRow) -> [LeoDispatchNode] {
        snapshot.dispatchChildren[row.name] ?? []
    }

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
