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
        didSet { recompute() }
    }
    /// Inline message from a failed attach/spawn, shown as a footer in the
    /// palette so the user can try another row without the panel closing.
    /// Cleared explicitly by the presenter (`clearFailure()`) whenever a new
    /// gesture or a fresh attempt begins -- never by `update(...)` itself,
    /// since live snapshot refreshes (agents starting/stopping) must not
    /// silently dismiss a still-relevant error.
    @Published private(set) var attachError: String?

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

    func reportFailure(_ message: String) {
        attachError = message
    }

    func clearFailure() {
        attachError = nil
    }

    func confirm() -> LeoPickerChoice? {
        guard let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        let row = rows[selectedIndex]
        guard isConfirmable(row) else { return nil }
        switch row {
        case .agent(let agentRow): return .agent(agentRow.identity)
        case .newAgent: return .newAgent
        case .plainShell: return .plainShell
        case .status: return nil
        }
    }

    func cancel() -> LeoPickerChoice { .cancel }

    /// Invokes the injected retry closure. Callers (the palette view) are
    /// expected to only surface the retry affordance when the current
    /// selection is a `.status(canRetry: true)` row, but this is safe to
    /// call unconditionally -- retrying a connected/connecting host is a
    /// harmless no-op at the `LeoHostSelection` layer.
    func retryConnection() {
        retry()
    }

    private func recompute() {
        let previous = selectedRowIdentity
        rows = buildRows()
        restoreSelection(previous)
    }

    private func buildRows() -> [Row] {
        switch hostState {
        case .connecting:
            return [.status(text: "Connecting to \(selectedHost.displayName)…", hint: nil, canRetry: false)] + trailingRows()
        case .failed(let message, let hint):
            return [.status(text: message, hint: hint, canRetry: true)] + trailingRows()
        case .connected:
            return filteredAgentRows().map(Row.agent) + trailingRows()
        }
    }

    private func trailingRows() -> [Row] {
        [.newAgent, .plainShell]
    }

    private func filteredAgentRows() -> [LeoAgentRow] {
        guard let snapshot else { return [] }
        let scoped = snapshot.rows.filter { $0.host == selectedHost }
        let ranked = LeoSidebarReducers.rank(scoped)
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ranked }
        return ranked.filter {
            $0.name.range(of: needle, options: .caseInsensitive) != nil ||
                ($0.repo?.range(of: needle, options: .caseInsensitive) != nil)
        }
    }

    private func isConfirmable(_ row: Row) -> Bool {
        switch row {
        case .agent: true
        case .newAgent: isConnected
        case .plainShell: true
        case .status: false
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
        case .status: .status
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
