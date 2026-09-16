import Combine
import Foundation

@MainActor final class LeoSidebarModel: ObservableObject {
    @Published private(set) var snapshot: LeoSidebarSnapshot
    @Published var query = ""
    @Published var selection: LeoAgentRow.ID?
    var attachRequested: (LeoAgentRow, AttachDisposition) -> Void = { _, _ in }
    var startDaemonRequested: () -> Void = {}
    var retryRequested: () -> Void = {}

    init(snapshot: LeoSidebarSnapshot = .init(rows: [], connectivity: .loading, generation: 0)) { self.snapshot = snapshot }

    var visibleRows: [LeoAgentRow] { LeoSidebarReducers.filter(LeoSidebarReducers.rank(snapshot.rows), query: query) }

    func receive(_ value: LeoSidebarSnapshot) {
        guard value.generation >= snapshot.generation else { return }
        snapshot = value
        guard let selection, !value.rows.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
    }

    func retry() { retryRequested() }
}
