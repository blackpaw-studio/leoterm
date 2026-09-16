import Combine
import Foundation

@MainActor final class LeoSidebarModel: ObservableObject {
    @Published private(set) var snapshot: LeoSidebarSnapshot
    @Published var query = ""
    @Published var selection: LeoAgentRow.ID?
    @Published private(set) var rowErrors: [LeoAgentRow.ID: String] = [:]
    var attachRequested: (LeoAgentRow, LeoWindowID, AttachDisposition) -> Void = { _, _, _ in }
    var startDaemonRequested: () -> Void = {}
    var retryRequested: () -> Void = {}

    init(snapshot: LeoSidebarSnapshot = .init(rows: [], connectivity: .loading, generation: 0)) { self.snapshot = snapshot }

    var visibleRows: [LeoAgentRow] { LeoSidebarReducers.filter(LeoSidebarReducers.rank(snapshot.rows), query: query) }

    func receive(_ value: LeoSidebarSnapshot) {
        guard value.generation >= snapshot.generation else { return }
        snapshot = value
        if value.connectivity == .connected { rowErrors = [:] }
        guard let selection, !value.rows.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
    }

    func retry() { retryRequested() }
    func reportAttachError(_ error: LeoAttachError, for id: LeoAgentRow.ID) { rowErrors[id] = error.message }
    func setRowError(_ id: LeoAgentRow.ID, message: String) { rowErrors[id] = message }
}
