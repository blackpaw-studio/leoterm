import Combine
import Foundation

@MainActor final class LeoSidebarModel: ObservableObject {
    @Published private(set) var snapshot: LeoSidebarSnapshot
    @Published var query = ""
    @Published var selection: LeoAgentRow.ID?
    @Published private(set) var rowErrors: [LeoAgentRow.ID: String] = [:]
    @Published private(set) var rowErrorCodes: [LeoAgentRow.ID: String] = [:]
    var attachRequested: (LeoAgentRow, LeoWindowID, AttachDisposition) -> Void = { _, _, _ in }
    var startDaemonRequested: () -> Void = {}
    var retryRequested: () -> Void = {}

    init(snapshot: LeoSidebarSnapshot = .init(rows: [], connectivity: .loading, generation: 0)) { self.snapshot = snapshot }

    var visibleRows: [LeoAgentRow] { LeoSidebarReducers.filter(LeoSidebarReducers.rank(snapshot.rows), query: query) }

    func receive(_ value: LeoSidebarSnapshot) {
        guard value.generation >= snapshot.generation else { return }
        snapshot = value
        if value.listRefreshSucceeded {
            rowErrors = [:]
            rowErrorCodes = [:]
        }
        guard let selection, !value.rows.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
    }

    func retry() { retryRequested() }
    func setRowError(_ message: String, code: String? = nil, for id: LeoAgentRow.ID) {
        rowErrors[id] = message
        rowErrorCodes[id] = code
    }

    func setRowError(_ id: LeoAgentRow.ID, message: String) {
        setRowError(message, for: id)
    }
}
