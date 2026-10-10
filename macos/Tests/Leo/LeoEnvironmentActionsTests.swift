import Combine
import Foundation
import Testing
@testable import Ghostty

/// B-283: the catalog comes from the bound daemon (so it is the same over
/// the SSH tunnel); a set goes through the row's action path, so its error
/// shows on the row like any other.
@MainActor struct LeoEnvironmentActionsTests {
    private static let catalog = LeoEnvironmentCatalog(names: ["aws", "prod", "dev"], templateDefaults: ["claude": ["aws", "prod"]])

    private func actions(_ daemon: EnvironmentDaemon, model: LeoSidebarModel? = nil) -> LeoAgentActions {
        LeoAgentActions(
            daemon: daemon, cli: .recordingForTests(templates: []), model: model ?? LeoSidebarModel(), hostSelection: .isolatedForTesting(),
            processRunner: LeoRecordingTemplateRunner(), refresh: {}
        )
    }

    private let row = LeoAgentRow(host: .local, name: "alpha", template: "claude", status: .running, activity: .unknown, actionDetail: nil)

    @Test func setEnvironmentsPostsTheList() async {
        let daemon = EnvironmentDaemon()
        let actions = actions(daemon)
        actions.setEnvironments(row, names: ["prod", "aws"])
        await awaitCondition { await daemon.calls == ["set:alpha:prod,aws"] }
    }

    @Test func setEnvironmentsErrorShowsOnRow() async {
        let daemon = EnvironmentDaemon(error: .daemon(code: "persistent_task", message: "alpha runs a persistent task", matches: []))
        let model = LeoSidebarModel()
        let actions = actions(daemon, model: model)
        actions.setEnvironments(row, names: [])
        await awaitCondition { await MainActor.run { model.rowErrors[row.id] == "alpha runs a persistent task" } }
    }

    @Test func catalogLoadsFromBoundDaemonAndFailsQuietly() async {
        let model = LeoSidebarModel()
        let actions = actions(EnvironmentDaemon(), model: model)
        actions.updateDaemon(EnvironmentDaemon(catalog: Self.catalog), host: .local)
        await awaitCondition { await MainActor.run { actions.environmentCatalog == .loaded(Self.catalog) } }

        actions.updateDaemon(EnvironmentDaemon(error: .daemon(code: "http_404", message: "HTTP 404", matches: [])), host: .local)
        await awaitCondition { await MainActor.run { actions.environmentCatalog == .failed("HTTP 404") } }
        #expect(model.rowErrors.isEmpty)
    }

    // MARK: Spawn sheet

    private func spawnModel(supported: Bool = true) -> SpawnAgentModel {
        let model = SpawnAgentModel(
            templateList: Just(.loaded([LeoTemplate(name: "claude"), LeoTemplate(name: "bare")])).eraseToAnyPublisher(),
            environmentCatalog: Just(.loaded(Self.catalog)).eraseToAnyPublisher(), environmentsSupported: supported
        )
        model.template = "claude"
        return model
    }

    @Test func prefillsTemplateDefault() {
        let model = spawnModel()
        #expect(model.environments.names == ["aws", "prod"])
        model.template = "bare"
        #expect(model.environments.names.isEmpty)
    }

    @Test func untouchedPrefillNotSent() {
        #expect(spawnModel().request().environments == nil)
    }

    @Test func editedListSentInOrder() {
        let model = spawnModel()
        model.environments = model.environments.adding("dev").moving("aws", by: 1)
        #expect(model.request().environments == ["prod", "aws", "dev"])
    }

    @Test func hiddenAndUnsentWithoutFeature() {
        let model = spawnModel(supported: false)
        #expect(!model.showsEnvironments)
        model.environments = LeoEnvironmentList(["dev"])
        #expect(model.request().environments == nil)
    }

    @Test func spawnErrorShowsDaemonMessage() async {
        let daemon = EnvironmentDaemon(error: .daemon(code: "unknown_environment", message: "unknown environment \"dev\"", matches: []))
        let actions = actions(daemon)
        let model = spawnModel()
        model.spawn(model.request(), actions: actions, attach: { _, _ in }, dismiss: {})
        await awaitCondition { await MainActor.run { model.error == "unknown environment \"dev\"" } }
    }
}

private actor EnvironmentDaemon: LeoDaemonClient {
    private(set) var calls: [String] = []
    private let error: LeoDaemonError?
    private let catalog: LeoEnvironmentCatalog

    init(error: LeoDaemonError? = nil, catalog: LeoEnvironmentCatalog = LeoEnvironmentCatalog(names: [])) {
        self.error = error
        self.catalog = catalog
    }

    func environmentCatalog() async throws -> LeoEnvironmentCatalog {
        if let error { throw error }
        return catalog
    }
    func setEnvironments(_ name: String, names: [String]) async throws {
        calls.append("set:\(name):\(names.joined(separator: ","))")
        if let error { throw error }
    }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent {
        if let error { throw error }
        return LeoAgent(name: "a", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: nil, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }
    func listAgents() async throws -> [LeoAgent] { [] }
    func start(_ name: String) async throws {}
    func stop(_ name: String, wakeOnMessage: Bool?) async throws {}
    func restart(_ name: String) async throws -> LeoAgent { try await spawn(LeoSpawnRequest()) }
    func reset(_ name: String) async throws {}
    func setTemplate(_ name: String, template: String) async throws {}
    func rename(_ name: String, newName: String) async throws -> LeoAgent { try await spawn(LeoSpawnRequest()) }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws {}
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { LeoDeletePlan(name: name, hasWorktree: false, branch: nil, worktreePath: nil) }
    func logs(_ name: String, lines: Int?) async throws -> String { "" }
}
