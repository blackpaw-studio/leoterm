import Foundation
import LeoKit

/// One machine as the palette sees it: its connection and its sidebar
/// snapshot, if one has landed.
struct LeoPaletteMachine: Equatable {
    let host: LeoHostID
    let state: LeoHostConnectionState
    let snapshot: LeoSidebarSnapshot?

    /// The sidebar's machines, in its order. This Mac's socket needs no
    /// tunnel, so it counts as connected before its connection first reports.
    static func list(
        order: [LeoHostID], snapshots: [LeoHostID: LeoSidebarSnapshot], state: (LeoHostID) -> LeoHostConnectionState?
    ) -> [LeoPaletteMachine] {
        LeoSidebarModel.machineHosts(order: order, snapshots: snapshots).map { host in
            let fallback: LeoHostConnectionState = host == .local ? .connected(socketPath: "") : .connecting
            return LeoPaletteMachine(host: host, state: state(host) ?? fallback, snapshot: snapshots[host])
        }
    }
}

/// Pure view-model for the agent picker palette. Consumes every machine's
/// sidebar snapshot + connection state and exposes a flat, keyboard-navigable
/// row list plus a `confirm()`/`cancel()` contract. No AppKit.
@MainActor final class LeoAgentPaletteModel: ObservableObject {
    enum Row: Equatable {
        case agent(LeoAgentRow)
        case newAgent
        case plainShell
        /// A machine that is connecting or failed (Q2).
        case status(host: LeoHostID, text: String, hint: String?, canRetry: Bool)
        /// The sidebar's disconnected banner itself (D-061), so the palette
        /// shows the same words with the same one-line reason (B-041).
        case disconnected(host: LeoHostID, banner: LeoDisconnectedBanner)
    }

    private enum RowIdentity: Equatable {
        case agent(LeoAgentRow.ID)
        case newAgent
        case plainShell
        case status(LeoHostID)
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var selectedIndex: Int?
    @Published var filterText: String = "" {
        didSet { recompute(preserveSelection: false) }
    }
    /// Inline message from a failed attach/spawn, shown as a footer in the
    /// palette so the user can try another row without the panel closing.
    /// Cleared explicitly by the presenter (`clearFailure()`) whenever a new
    /// gesture or a fresh attempt begins -- never by `update(...)` itself,
    /// since live snapshot refreshes (agents starting/stopping) must not
    /// silently dismiss a still-relevant error.
    @Published private(set) var attachError: String?
    /// Whether ⌘Return (a new window, D-104) is worth a hint: a Choose
    /// Agent… (⌘O) or start-screen request, not a split. Set by the presenter per request.
    @Published var offersNewWindow = false

    private let retry: (LeoHostID) -> Void
    private var machines: [LeoPaletteMachine] = []
    private var selectedRowIdentity: RowIdentity?

    init(retry: @escaping (LeoHostID) -> Void = { _ in }) {
        self.retry = retry
    }

    /// Every shown machine, in sidebar order.
    func update(machines: [LeoPaletteMachine]) {
        self.machines = machines
        recompute()
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else {
            selectedIndex = nil
            selectedRowIdentity = nil
            return
        }
        let current = selectedIndex ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        selectedIndex = next
        selectedRowIdentity = identity(for: rows[next])
    }

    /// Selects `index` directly (a mouse click on a row), clamping bookkeeping
    /// the same way `moveSelection` does. A no-op for an out-of-range index.
    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        selectedRowIdentity = identity(for: rows[index])
    }

    /// Name characters to draw bold for the current filter, as the sidebar
    /// does (B-042).
    func nameHighlights(for row: LeoAgentRow) -> [Int] {
        LeoFuzzyMatcher.nameHighlights(for: row, query: filterText)
    }

    func reportFailure(_ message: String) {
        attachError = message
    }

    func clearFailure() {
        attachError = nil
    }

    /// `placement` is Return's (`.requested`) or ⌘Return's (`.newWindow`);
    /// only an agent row carries it.
    func confirm(placement: LeoAttachPlacement = .requested) -> LeoPickerChoice? {
        guard let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        let row = rows[selectedIndex]
        guard isConfirmable(row) else { return nil }
        switch row {
        case .agent(let agentRow): return .agent(agentRow.identity, placement: placement)
        case .newAgent: return .newAgent
        case .plainShell: return .plainShell
        case .status, .disconnected: return nil
        }
    }

    func cancel() -> LeoPickerChoice { .cancel }

    /// Reconnects `host`: the Retry on its `.status(canRetry: true)` or
    /// `.disconnected` row. Safe for any machine; reconnecting one that is
    /// connecting just starts its attempt over.
    func retryConnection(_ host: LeoHostID) {
        retry(host)
    }

    private func recompute(preserveSelection: Bool = true) {
        let previous = preserveSelection ? selectedRowIdentity : nil
        rows = buildRows()
        // A filter-text change always resets to the top of the new list
        // (the first matching agent, or "New agent…" when nothing
        // matches) rather than clamping against the previous index, which
        // could land on an unrelated row once the list shrinks.
        if !preserveSelection { selectedIndex = nil }
        restoreSelection(previous)
    }

    /// Every connected machine's agents ranked together, then a row per
    /// machine that is connecting, failed or disconnected, so a machine
    /// that is down never takes Return from the top agent.
    private func buildRows() -> [Row] {
        let agents = machines.flatMap(agentRows(of:))
        let ranked = LeoFuzzyMatcher.rank(LeoSidebarReducers.rank(agents), query: filterText, secondary: \.repo)
        return ranked.map(Row.agent) + machines.compactMap(statusRow(of:)) + trailingRows()
    }

    private func statusRow(of machine: LeoPaletteMachine) -> Row? {
        let host = machine.host
        switch machine.state {
        case .connecting:
            return .status(host: host, text: "Connecting to \(LeoSFTPServerText.sanitized(host.displayName))…", hint: nil, canRetry: false)
        case .failed(let message, let hint):
            // Remote ssh stderr: through the one sanitizer (B-020).
            return .status(host: host, text: LeoSFTPServerText.sanitized(message), hint: hint.map(LeoSFTPServerText.sanitized), canRetry: true)
        case .connected:
            return disconnectedBanner(of: machine).map { .disconnected(host: host, banner: $0) }
        }
    }

    /// A connected machine's own agents; none while it's disconnected.
    private func agentRows(of machine: LeoPaletteMachine) -> [LeoAgentRow] {
        guard case .connected = machine.state, disconnectedBanner(of: machine) == nil, let snapshot = machine.snapshot else { return [] }
        return snapshot.rows.filter { $0.host == machine.host }
    }

    private func disconnectedBanner(of machine: LeoPaletteMachine) -> LeoDisconnectedBanner? {
        machine.snapshot.flatMap { LeoDisconnectedBanner(host: machine.host, connectivity: $0.connectivity) }
    }

    private func trailingRows() -> [Row] {
        [.newAgent, .plainShell]
    }

    private func isConfirmable(_ row: Row) -> Bool {
        switch row {
        case .agent: true
        case .newAgent: isAnyMachineConnected
        case .plainShell: true
        case .status, .disconnected: false
        }
    }

    private var isAnyMachineConnected: Bool {
        machines.contains { if case .connected = $0.state { true } else { false } }
    }

    private func identity(for row: Row) -> RowIdentity {
        switch row {
        case .agent(let agentRow): .agent(agentRow.id)
        case .newAgent: .newAgent
        case .plainShell: .plainShell
        case .status(let host, _, _, _), .disconnected(let host, _): .status(host)
        }
    }

    private func restoreSelection(_ previous: RowIdentity?) {
        guard !rows.isEmpty else {
            selectedIndex = nil
            selectedRowIdentity = nil
            return
        }
        if let previous, let index = rows.firstIndex(where: { identity(for: $0) == previous }) {
            selectedIndex = index
            selectedRowIdentity = previous
            return
        }
        let clamped = min(selectedIndex ?? 0, rows.count - 1)
        selectedIndex = clamped
        selectedRowIdentity = identity(for: rows[clamped])
    }
}
