import Combine
import Foundation
import LeoKit

@MainActor final class LeoSidebarModel: ObservableObject {
    /// One snapshot per machine, fed by that machine's own feed. A machine
    /// that has delivered nothing yet has no entry.
    @Published private(set) var snapshots: [LeoHostID: LeoSidebarSnapshot]
    /// The machines to show, in display order (This Mac first, then
    /// Settings order). Empty until `setMachines`: the model then shows
    /// whichever machines have delivered a snapshot.
    @Published private(set) var machineOrder: [LeoHostID] = []
    /// Where each shown machine's connection stands, for the spawn sheet's
    /// Machine field (the sidebar itself reads snapshots).
    @Published private(set) var machineStatuses: [LeoHostID: LeoMachineStatus] = [:]
    /// The latest CPU/memory/disk sample per connected machine.
    @Published private(set) var machineStats: [LeoHostID: LeoSidebarMachineStats] = [:]
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
    /// Set while the app runs outside /Applications and the user declined
    /// (or failed) the move; managed features stay off meanwhile (A9).
    @Published var appLocationBanner: LeoAppLocationBanner?
    var moveToApplicationsRequested: () -> Void = {}
    /// B5: the local managed daemon's banner, and what "Start daemon" does.
    @Published private(set) var managedBanner: LeoManagedBanner?
    @Published private(set) var daemonStartAction: LeoDaemonStartAction = .startCLIDaemon
    var managedBannerActionRequested: (LeoManagedBannerAction) -> Void = { _ in }
    /// Unset when the app manages nothing: the button runs the CLI command.
    var daemonStartActionRequested: ((LeoDaemonStartAction) -> Void)?
    var retryRequested: () -> Void = {}
    /// Per-machine header actions: Reconnect, Edit Machine…, New Agent Here….
    var reconnectRequested: (LeoHostID) -> Void = { _ in }
    var editMachineRequested: (LeoHostID) -> Void = { _ in }
    var newAgentHereRequested: (LeoHostID) -> Void = { _ in }
    /// The hint and ssh target behind a machine's failed connection, for
    /// its Open SSH; nil without one.
    var connectionFailureHint: (LeoHostID) -> LeoConnectionFailureHint? = { _ in nil }
    var sshRequested: (String) -> Void = { _ in }
    /// Fired when the Dock attention count changes (AppDelegate's badge writer).
    var attentionCountChanged: (Int) -> Void = { _ in }

    /// Sort order, pins and collapsed sections (B-010), saved to
    /// `preferencesStore` on every change.
    @Published private(set) var preferences: LeoSidebarPreferences
    private let preferencesStore: any LeoSidebarPreferencesStore

    func managedPresentationChanged(_ presentation: LeoManagedPresentation) {
        managedBanner = presentation.banner
        daemonStartAction = presentation.startAction
    }

    /// The local "Start daemon" button.
    func startDaemonTapped() {
        guard let daemonStartActionRequested else {
            startDaemonRequested()
            return
        }
        daemonStartActionRequested(daemonStartAction)
    }

    init(
        snapshot: LeoSidebarSnapshot = .init(rows: [], connectivity: .loading, generation: 0),
        preferencesStore: any LeoSidebarPreferencesStore = LeoInMemorySidebarPreferencesStore()
    ) {
        snapshots = [snapshot.rows.first?.host ?? .local: snapshot]
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
    }

    /// Every row of every machine, machines in display order.
    var rows: [LeoAgentRow] { machineHosts.flatMap { snapshots[$0]?.rows ?? [] } }

    /// Every machine's sections in one list; with one machine, that
    /// machine's. Section ids repeat across machines, so the view draws
    /// `machineSections` instead.
    var sections: [LeoSidebarSection] { machineSections.flatMap(\.sections) }

    /// Rows a person can see, top to bottom: each open machine's visible
    /// rows in machine order. A filter shows matches in every machine.
    var visibleRows: [LeoAgentRow] {
        let isFiltering = LeoSidebarLayout.isFiltering(query)
        return machineHosts
            .filter { isFiltering || !isMachineCollapsed($0) }
            .flatMap { host in
                LeoSidebarLayout.visibleRows(
                    rows: snapshots[host]?.rows ?? [], query: query, preferences: preferences, host: host
                )
            }
    }

    /// Only the filter can leave nothing to show: collapsed sections keep
    /// their headers, which are how they're expanded again.
    var showsNoMatches: Bool { !rows.isEmpty && machineSections.allSatisfy { $0.sections.isEmpty } }

    /// Every row in unfiltered display order, collapsed ones included.
    var orderedRows: [LeoAgentRow] {
        machineHosts.flatMap { LeoSidebarLayout.orderedRows(snapshots[$0]?.rows ?? [], preferences: preferences) }
    }

    func setSortOrder(_ order: LeoSidebarSortOrder) { update(preferences.with(sortOrder: order)) }

    func setGroupBy(_ groupBy: LeoSidebarGroupBy) { update(preferences.with(groupBy: groupBy)) }

    func isPinned(_ id: LeoAgentRow.ID) -> Bool { preferences.pinned.contains(id) }

    func togglePin(_ id: LeoAgentRow.ID) { update(preferences.togglingPin(id)) }

    /// Collapsed sections are remembered per machine.
    func isCollapsed(_ sectionID: String, host: LeoHostID) -> Bool { preferences.isCollapsed(sectionID, host: host) }

    func toggleCollapsed(_ sectionID: String, host: LeoHostID) {
        guard sectionID != LeoSidebarLayout.needsYouSectionID else { return }
        update(preferences.setting(sectionID, collapsed: !isCollapsed(sectionID, host: host), host: host))
    }

    func toggleMachineCollapsed(_ host: LeoHostID) {
        update(preferences.setting(machine: host, collapsed: !isMachineCollapsed(host)))
    }

    /// Expands the machine and section holding `id`, so a row something
    /// jumps to is on screen.
    func reveal(_ id: LeoAgentRow.ID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        let sectionID = LeoSidebarLayout.sectionID(of: row, preferences: preferences)
        var revealed = preferences.setting(machine: row.host, collapsed: false)
        if revealed.isCollapsed(sectionID, host: row.host) {
            revealed = revealed.setting(sectionID, collapsed: false, host: row.host)
        }
        update(revealed)
    }

    private func update(_ updated: LeoSidebarPreferences) {
        guard updated != preferences else { return }
        preferences = updated
        preferencesStore.save(updated)
    }

    /// A machine's snapshot, from that machine's own feed. The generation
    /// guard is per machine: another machine's higher generation never
    /// drops it.
    func receive(_ value: LeoSidebarSnapshot, for host: LeoHostID) {
        guard isShown(host), value.generation >= snapshots[host]?.generation ?? value.generation else { return }
        let previousAttentionCount = attentionCount
        let previousRows = rows
        snapshots = snapshots.merging([host: value]) { _, new in new }
        #if DEBUG
        LeoLaunchTiming.mark("firstSnapshot", "connectivity=\(value.connectivity) rows=\(value.rows.count)")
        if !value.rows.isEmpty { LeoLaunchTiming.mark("firstRows", "rows=\(value.rows.count)") }
        #endif
        defer { reapplyFocusedRow(previousRows: previousRows) }
        if attentionCount != previousAttentionCount { attentionCountChanged(attentionCount) }
        if value.listRefreshSucceeded { clearRowErrors(where: { $0.host == host }) }
        resolveStartPrompts()
        reconcileDispatchSelection()
        pruneCollapsedDispatches()
        guard let selection, selection.host == host,
              !value.rows.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
    }

    /// The spawn picker's machine statuses, as the registry reports them.
    func setMachineStatuses(_ statuses: [LeoHostID: LeoMachineStatus]) {
        machineStatuses = statuses
    }

    /// The machines to show, in order. A machine that left the list loses
    /// its rows, stats, errors and selection, and its late snapshots are
    /// ignored; the arrangement preferences (pins, collapsed sections)
    /// stay for when it returns.
    func setMachines(_ hosts: [LeoHostID]) {
        let previousAttentionCount = attentionCount
        machineOrder = hosts
        let kept = Set(hosts)
        snapshots = snapshots.filter { kept.contains($0.key) }
        machineStats = machineStats.filter { kept.contains($0.key) }
        clearRowErrors(where: { !kept.contains($0.host) })
        resolveStartPrompts()
        reconcileDispatchSelection()
        pruneCollapsedDispatches()
        if attentionCount != previousAttentionCount { attentionCountChanged(attentionCount) }
        guard let selection, !kept.contains(selection.host) else { return }
        self.selection = nil
    }

    /// A machine's latest stats sample; nil clears it (no stats to show).
    func receiveStats(_ stats: LeoSidebarMachineStats?, for host: LeoHostID) {
        guard isShown(host) else { return }
        machineStats[host] = stats
    }

    private func clearRowErrors(where matches: (LeoAgentRow.ID) -> Bool) {
        rowErrors = rowErrors.filter { !matches($0.key) }
        rowErrorCodes = rowErrorCodes.filter { !matches($0.key) }
    }

    func retry() { retryRequested() }

    /// Rows are shown but inert while their machine is disconnected (D-061).
    func isDisconnected(_ host: LeoHostID) -> Bool { snapshots[host]?.connectivity.isDisconnected ?? false }

    /// What `host`'s daemon advertised; none until it connects.
    func features(for host: LeoHostID) -> LeoDaemonFeatures { snapshots[host]?.features ?? .none }

    func snapshot(for host: LeoHostID) -> LeoSidebarSnapshot? { snapshots[host] }

    /// Agents needing attention across every machine: the Dock badge.
    var attentionCount: Int { snapshots.values.reduce(0) { $0 + $1.attentionCount } }

    /// The live dispatches nested under `row` (B-257), depth first.
    func dispatchChildren(for row: LeoAgentRow) -> [LeoDispatchNode] {
        snapshots[row.host]?.dispatchChildren[row.name] ?? []
    }

    var selectedRow: LeoAgentRow? { selection.flatMap { id in rows.first { $0.id == id } } }

    /// The selected row, when agent commands may act on it: never while
    /// its machine is disconnected.
    var actionableSelection: LeoAgentRow? { selectedRow.flatMap { isDisconnected($0.host) ? nil : $0 } }

    /// Every sidebar attach goes through here; a no-op while the row's
    /// machine is disconnected.
    func requestAttach(_ row: LeoAgentRow, from windowID: LeoWindowID, disposition: AttachDisposition) {
        guard !isDisconnected(row.host) else { return }
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
