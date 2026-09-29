import Foundation

/// Pure view-model for the agent picker palette. Consumes the sidebar's
/// snapshot + host connection state and exposes a flat, keyboard-navigable
/// row list plus a `confirm()`/`cancel()` contract. No AppKit.
@MainActor final class LeoAgentPaletteModel: ObservableObject {
    enum Row: Equatable {
        case agent(LeoAgentRow)
        case newAgent
        case plainShell
        case status(text: String, hint: String?, canRetry: Bool)
        /// The sidebar's disconnected banner itself (D-061), so the palette
        /// shows the same words with the same one-line reason (B-041).
        case disconnected(LeoDisconnectedBanner)
    }

    private enum RowIdentity: Equatable {
        case agent(LeoAgentRow.ID)
        case newAgent
        case plainShell
        case status
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

    private let retry: () -> Void
    private var snapshot: LeoSidebarSnapshot?
    private var selectedHost: LeoHostID = .local
    private var hostState: LeoHostConnectionState = .connecting
    private var selectedRowIdentity: RowIdentity?

    init(retry: @escaping () -> Void = {}) {
        self.retry = retry
    }

    func update(snapshot: LeoSidebarSnapshot, selectedHost: LeoHostID, hostState: LeoHostConnectionState) {
        self.snapshot = snapshot
        self.selectedHost = selectedHost
        self.hostState = hostState
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

    /// Invokes the injected retry closure. Callers (the palette view) are
    /// expected to only surface the retry affordance when the current
    /// selection is a `.status(canRetry: true)` row (or a `.disconnected`
    /// one that isn't already retrying), but this is safe to
    /// call unconditionally -- retrying a connected/connecting host is a
    /// harmless no-op at the `LeoHostSelection` layer.
    func retryConnection() {
        retry()
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

    private func buildRows() -> [Row] {
        switch hostState {
        case .connecting:
            return [.status(text: "Connecting to \(LeoSFTPServerText.sanitized(selectedHost.displayName))…", hint: nil, canRetry: false)] + trailingRows()
        case .failed(let message, let hint):
            // Remote ssh stderr: through the one sanitizer (B-020).
            return [.status(text: LeoSFTPServerText.sanitized(message), hint: hint.map(LeoSFTPServerText.sanitized), canRetry: true)] + trailingRows()
        case .connected:
            if let banner = snapshot.flatMap({ LeoDisconnectedBanner(host: selectedHost, connectivity: $0.connectivity) }) {
                return [.disconnected(banner)] + trailingRows()
            }
            return filteredAgentRows().map(Row.agent) + trailingRows()
        }
    }

    private func trailingRows() -> [Row] {
        [.newAgent, .plainShell]
    }

    private func filteredAgentRows() -> [LeoAgentRow] {
        guard let snapshot else { return [] }
        let scoped = snapshot.rows.filter { $0.host == selectedHost }
        // The sidebar's fuzzy matcher (B-042), over name then repo -- the
        // two fields a palette row shows. Ties keep the sidebar order.
        return LeoFuzzyMatcher.rank(LeoSidebarReducers.rank(scoped), query: filterText, secondary: \.repo)
    }

    private func isConfirmable(_ row: Row) -> Bool {
        switch row {
        case .agent: true
        case .newAgent: isConnected
        case .plainShell: true
        case .status, .disconnected: false
        }
    }

    private var isConnected: Bool {
        if case .connected = hostState { true } else { false }
    }

    private func identity(for row: Row) -> RowIdentity {
        switch row {
        case .agent(let agentRow): .agent(agentRow.id)
        case .newAgent: .newAgent
        case .plainShell: .plainShell
        case .status, .disconnected: .status
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
