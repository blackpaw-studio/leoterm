import Combine
import Foundation

@MainActor final class LeoAgentActions: ObservableObject {
    @Published private(set) var pendingActions: Set<LeoAgentRow.ID> = []
    private let daemon: any LeoDaemonClient
    private let cli: LeoCLI
    private let model: LeoSidebarModel
    private let refresh: () -> Void
    var deletePlanSink: (LeoDeletePlan) -> Void = { _ in }
    var cliForSpawn: LeoCLI { cli }

    init(daemon: any LeoDaemonClient, cli: LeoCLI, model: LeoSidebarModel, refresh: @escaping () -> Void) {
        self.daemon = daemon; self.cli = cli; self.model = model; self.refresh = refresh
    }

    func start(_ row: LeoAgentRow) { run(row) { try await self.daemon.start(row.name) } }
    func stop(_ row: LeoAgentRow) { run(row) { try await self.daemon.stop(row.name, wakeOnMessage: nil) } }
    func restart(_ row: LeoAgentRow) { run(row) { _ = try await self.daemon.restart(row.name) } }
    func setTemplate(_ row: LeoAgentRow, template: String) { run(row) { try await self.daemon.setTemplate(row.name, template: template) } }
    func rename(_ row: LeoAgentRow, newName: String) { run(row) { _ = try await self.daemon.rename(row.name, newName: newName) } }
    func delete(_ row: LeoAgentRow, force: Bool, deleteBranch: Bool) { run(row) { try await self.daemon.delete(row.name, force: force, deleteBranch: deleteBranch) } }
    func deletePlan(_ row: LeoAgentRow) {
        run(row, refreshOnSuccess: false) { [weak self] in
            guard let self else { return }
            let plan = try await self.daemon.deletePlan(row.name)
            self.deletePlanSink(plan)
        }
    }
    func viewLogs(_ row: LeoAgentRow) { run(row) { _ = try await self.daemon.logs(row.name, lines: nil) } }
    func spawn(_ request: LeoSpawnRequest, attach: @escaping (LeoAgentRow, AttachDisposition) -> Void, dismiss: @escaping () -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let agent = try await daemon.spawn(request)
                dismiss(); refresh()
                attach(LeoAgentRow(host: .local, name: agent.name, template: agent.template, status: agent.status ?? .unknown("unknown"), activity: .unknown, actionDetail: nil), .reuseOrTab)
            } catch {
                model.setRowError(Self.message(error), for: "spawn")
            }
        }
    }

    private func run(_ row: LeoAgentRow, refreshOnSuccess: Bool = true, operation: @escaping @MainActor () async throws -> Void) {
        guard pendingActions.insert(row.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingActions.remove(row.id) }
            do {
                try await operation()
                if refreshOnSuccess { self.refresh() }
            } catch {
                self.model.setRowError(Self.message(error), for: row.id)
            }
        }
    }

    private static func message(_ error: Error) -> String {
        if case let LeoDaemonError.daemon(_, message, _) = error { return message }
        return error.localizedDescription
    }
}
