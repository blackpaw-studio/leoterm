import Combine
import Foundation

@MainActor final class LeoAgentActions: ObservableObject {
    @Published private(set) var pendingActions: Set<LeoAgentRow.ID> = []
    private let daemon: any LeoDaemonClient
    private let cli: LeoCLI
    private let model: LeoSidebarModel
    private let refresh: () -> Void
    var cliForSpawn: LeoCLI { cli }
    private let clock: @Sendable () -> Date
    private var cachedTemplates: (value: [LeoTemplate], fetchedAt: Date)?

    init(daemon: any LeoDaemonClient, cli: LeoCLI, model: LeoSidebarModel,
         refresh: @escaping () -> Void, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.daemon = daemon
        self.cli = cli
        self.model = model
        self.refresh = refresh
        self.clock = clock
    }

    func start(_ row: LeoAgentRow) { run(row) { try await self.daemon.start(row.name) } }
    func stop(_ row: LeoAgentRow) { run(row) { try await self.daemon.stop(row.name, wakeOnMessage: nil) } }
    func restart(_ row: LeoAgentRow) { run(row) { _ = try await self.daemon.restart(row.name) } }
    func setTemplate(_ row: LeoAgentRow, template: String) { run(row) { try await self.daemon.setTemplate(row.name, template: template) } }
    func rename(_ row: LeoAgentRow, newName: String) { run(row) { _ = try await self.daemon.rename(row.name, newName: newName) } }
    func delete(_ row: LeoAgentRow, force: Bool, deleteBranch: Bool, success: @escaping () -> Void = {}) {
        run(row, success: success) { try await self.daemon.delete(row.name, force: force, deleteBranch: deleteBranch) }
    }
    func deletePlan(_ row: LeoAgentRow, receive: @escaping (LeoDeletePlan) -> Void) {
        run(row, refreshOnSuccess: false) { [weak self] in
            guard let self else { return }
            let plan = try await self.daemon.deletePlan(row.name)
            receive(plan)
        }
    }
    func templates() async throws -> [LeoTemplate] {
        if let cachedTemplates, clock().timeIntervalSince(cachedTemplates.fetchedAt) < 60 {
            return cachedTemplates.value
        }
        let value = try await cli.templateList()
        cachedTemplates = (value, clock())
        return value
    }
    func spawn(_ request: LeoSpawnRequest, attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
               dismiss: @escaping () -> Void, failure: @escaping (String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let agent = try await daemon.spawn(request)
                dismiss(); refresh()
                attach(LeoAgentRow(host: .local, name: agent.name, template: agent.template, status: agent.status ?? .unknown("unknown"), activity: .unknown, actionDetail: nil), .reuseOrTab)
            } catch {
                failure(Self.message(error))
            }
        }
    }

    private func run(_ row: LeoAgentRow, refreshOnSuccess: Bool = true, success: @escaping () -> Void = {},
                     operation: @escaping @MainActor () async throws -> Void) {
        guard pendingActions.insert(row.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingActions.remove(row.id) }
            do {
                try await operation()
                if refreshOnSuccess { self.refresh() }
                success()
            } catch {
                self.model.setRowError(Self.message(error), code: Self.code(error), for: row.id)
            }
        }
    }

    private static func message(_ error: Error) -> String {
        if case let LeoDaemonError.daemon(_, message, _) = error { return message }
        return error.localizedDescription
    }

    private static func code(_ error: Error) -> String? {
        if case let LeoDaemonError.daemon(code, _, _) = error { return code }
        return nil
    }
}
