import Combine
import Foundation
import Testing
@testable import Ghostty
@testable import LeoKit

/// B-176: "New Agent in Worktree…" from an agent row. The sheet prefills the
/// row's template, host and owner/repo, requires a branch, and spawns with
/// the daemon's `branch` field (what `leo agent spawn --worktree` sends) on
/// the selected host's daemon, local or tunnelled.
@MainActor struct LeoWorktreeSpawnTests {
    @Test(arguments: [LeoAgentStatus.running, .stopped])
    func rowAvailabilityDisablesWorktreeWithoutOwnerRepo(status: LeoAgentStatus) {
        #expect(!LeoRowActionAvailability(status: status, isPending: false).newWorktree)
        #expect(!LeoRowActionAvailability(status: status, isPending: false, repo: nil).newWorktree)
        #expect(!LeoRowActionAvailability(status: status, isPending: false, repo: "brand").newWorktree)
        #expect(LeoRowActionAvailability(status: status, isPending: false, repo: "blackpaw-studio/website").newWorktree)
    }

    @Test func worktreeModelPrefillsFromSourceRow() {
        let model = worktreeModel(source: sourceRow(host: .remote("work")))
        #expect(model.isWorktree)
        #expect(model.template == "claude")
        #expect(model.repo == "o/r")
        #expect(model.branch.isEmpty)
        #expect(model.name.isEmpty)
        #expect(model.prompt.isEmpty)
        #expect(model.validationError == "Branch is required")
    }

    @Test func worktreeRequestCarriesBranchAndRepo() {
        let model = worktreeModel(source: sourceRow(host: .local))
        model.branch = "feat/x"
        #expect(model.validationError == nil)
        #expect(model.request() == LeoSpawnRequest(template: "claude", repo: "o/r", name: nil, branch: "feat/x", base: nil, prompt: nil))
        model.name = "custom"
        model.prompt = "go"
        #expect(model.request() == LeoSpawnRequest(template: "claude", repo: "o/r", name: "custom", branch: "feat/x", base: nil, prompt: "go"))
    }

    /// A worktree runs where its source agent is: the Machine field shows
    /// that machine and a pick elsewhere is ignored.
    @Test func worktreeModelIsLockedToTheSourcesMachine() {
        let model = worktreeModel(source: sourceRow(host: .local), reachable: [.remote("work")])
        model.branch = "feat/x"
        #expect(model.isMachineLocked)
        model.choose(.remote("work"))
        #expect(model.machine == .local)
        #expect(model.validationError == nil)
    }

    @Test func worktreeModelOnARemoteSourceStartsOnThatMachine() {
        #expect(worktreeModel(source: sourceRow(host: .remote("work"))).machine == .remote("work"))
    }

    /// A plain New Agent sheet has no source, so its machine is free.
    @Test func plainModelIsNotLocked() {
        let model = worktreeModel(source: nil, reachable: [.remote("work")])
        #expect(!model.isWorktree)
        #expect(!model.isMachineLocked)
        model.choose(.remote("work"))
        #expect(model.machine == .remote("work"))
    }

    @Test func worktreeSpawnLocalSendsBranchAndSelectsRow() async throws {
        let daemon = WorktreeDaemon()
        try await spawnAndSelect(daemon: daemon, host: .local)
    }

    @Test func worktreeSpawnRemoteRunsOnRemoteHostAndSelectsRow() async throws {
        let localDaemon = WorktreeDaemon()
        let remoteDaemon = WorktreeDaemon()
        let sidebar = LeoSidebarModel()
        let clients = FakeMachineClients(daemons: [.local: localDaemon, .remote("work"): remoteDaemon])
        let actions = LeoAgentActions(clients: clients, cli: worktreeCLI(), model: sidebar, processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        try await spawnAndSelect(daemon: remoteDaemon, sidebar: sidebar, actions: actions, host: .remote("work"))
        #expect(await localDaemon.requests.isEmpty)
    }

    @Test func worktreeSpawnFailureKeepsSheetAndShowsError() async {
        let daemon = WorktreeDaemon(error: .daemon(code: "x", message: "branch exists", matches: []))
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: daemon), cli: worktreeCLI(), model: LeoSidebarModel(), processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        let model = worktreeModel(source: sourceRow(host: .local))
        model.branch = "feat/x"
        var dismissed = false
        var attached = false

        model.spawn(model.request(), actions: actions, attach: { _, _ in attached = true }, dismiss: { dismissed = true })

        await awaitCondition { await MainActor.run { model.error != nil } }
        #expect(model.error == "branch exists")
        #expect(!model.isSpawning)
        #expect(!dismissed)
        #expect(!attached)
        #expect(await daemon.requests.count == 1)
    }

    /// Review fix: a machine's client exists only once its tunnel is up. A
    /// spawn before then must never reach another machine's daemon.
    @Test func worktreeSpawnRefusesWhileTheMachineHasNoConnection() async {
        let localDaemon = WorktreeDaemon()
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: localDaemon), cli: worktreeCLI(), model: LeoSidebarModel(), processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        let model = worktreeModel(source: sourceRow(host: .remote("work")))
        model.branch = "feat/x"
        #expect(model.validationError == nil)
        var dismissed = false
        var attached = false

        model.spawn(model.request(), actions: actions, attach: { _, _ in attached = true }, dismiss: { dismissed = true })

        await awaitCondition { await MainActor.run { model.error != nil } }
        #expect(model.error == "Not connected to work yet")
        #expect(!model.isSpawning)
        #expect(!dismissed)
        #expect(!attached)
        for _ in 0..<20 { await Task.yield() }
        #expect(await localDaemon.requests.isEmpty)
    }

    /// The plain New Agent sheet spawns on its own machine, so the same
    /// window refuses it too.
    @Test func plainSpawnRefusesWhileTheMachineHasNoConnection() async {
        let localDaemon = WorktreeDaemon()
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: localDaemon), cli: worktreeCLI(), model: LeoSidebarModel(), processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        let model = worktreeModel(source: nil, context: .remote("work"))
        model.template = "claude"

        model.spawn(model.request(), actions: actions, attach: { _, _ in }, dismiss: {})

        await awaitCondition { await MainActor.run { model.error != nil } }
        #expect(model.error == "Not connected to work yet")
        #expect(!model.isSpawning)
        #expect(await localDaemon.requests.isEmpty)
    }

    /// A spawn whose answer lands after its machine reconnected is dropped,
    /// but the sheet must not stay stuck spawning, and says where it went.
    @Test func spawnResultDroppedByReconnectResetsTheSheet() async {
        let daemon = WorktreeDaemon(suspendSpawn: true)
        let clients = FakeMachineClients(daemon: daemon)
        let actions = LeoAgentActions(
            clients: clients, cli: worktreeCLI(), model: LeoSidebarModel(), processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        let model = worktreeModel(source: sourceRow(host: .local))
        model.branch = "feat/x"
        var dismissed = false
        var attached = false

        model.spawn(model.request(), actions: actions, attach: { _, _ in attached = true }, dismiss: { dismissed = true })
        await awaitCondition { await daemon.requests.count == 1 }
        clients.connect(.local, WorktreeDaemon())
        await daemon.resumeSpawn()

        await awaitCondition { await MainActor.run { !model.isSpawning } }
        #expect(model.error == "Host changed; the agent may have been created on localhost")
        #expect(!dismissed)
        #expect(!attached)
    }

    @Test func editingClearsAStaleSpawnError() {
        let model = worktreeModel(source: nil, reachable: [.remote("work")])
        let edits: [(SpawnAgentModel) -> Void] = [
            { $0.branch = "feat/y" }, { $0.name = "other" }, { $0.template = "claude" }, { $0.choose(.remote("work")) }
        ]
        for edit in edits {
            model.setError("branch exists")
            edit(model)
            #expect(model.error == nil)
        }
    }

    // MARK: - Helpers

    private func spawnAndSelect(daemon: WorktreeDaemon, host: LeoHostID) async throws {
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: worktreeCLI(), model: sidebar, processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        try await spawnAndSelect(daemon: daemon, sidebar: sidebar, actions: actions, host: host)
    }

    /// Drives the sheet's Create path: the model's request through the
    /// actions, attaching via the sidebar exactly as `LeoSidebarView` does,
    /// with `attachRequested` selecting the row as `LeoRuntime` wires it.
    private func spawnAndSelect(
        daemon: WorktreeDaemon, sidebar: LeoSidebarModel, actions: LeoAgentActions, host: LeoHostID
    ) async throws {
        sidebar.attachRequested = { [weak sidebar] row, _, _ in sidebar?.selection = row.id }
        let model = worktreeModel(source: sourceRow(host: host))
        model.branch = "feat/x"
        var dismissed = false
        let window = LeoWindowID()

        model.spawn(model.request(), actions: actions, attach: { row, disposition in
            sidebar.requestAttach(row, from: window, disposition: disposition)
        }, dismiss: { dismissed = true })

        await awaitCondition { await MainActor.run { sidebar.selection != nil } }
        let requests = await daemon.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.branch == "feat/x")
        #expect(request.repo == "o/r")
        #expect(request.template == "claude")
        #expect(request.base == nil)
        #expect(sidebar.selection == LeoAgentRow.ID(host: host, name: WorktreeDaemon.spawnedName))
        #expect(dismissed)
        #expect(!model.isSpawning)
    }

    private func sourceRow(host: LeoHostID) -> LeoAgentRow {
        LeoAgentRow(host: host, name: "source", template: "claude", status: .running, activity: .idle, actionDetail: nil, repo: "o/r")
    }

    /// The machine defaults to the source's own, as when the sheet opens
    /// from a row.
    private func worktreeModel(source: LeoAgentRow?, context: LeoHostID? = nil, reachable: [LeoHostID] = []) -> SpawnAgentModel {
        let list = Just(LeoTemplateListState.loaded([LeoTemplate(name: "claude")])).eraseToAnyPublisher()
        return SpawnAgentModel(templateList: list, source: source, context: context, reachable: reachable)
    }

    private func worktreeCLI() -> LeoCLI {
        .recordingForTests(templates: ["claude"])
    }
}

/// Records every spawn request and answers with the agent the daemon would
/// create for a worktree spawn.
actor WorktreeDaemon: LeoDaemonClient {
    static let spawnedName = "r-feat-x"
    private(set) var requests: [LeoSpawnRequest] = []
    private let error: LeoDaemonError?
    private let suspendSpawn: Bool
    private var spawnWaiter: CheckedContinuation<Void, Never>?

    init(error: LeoDaemonError? = nil, suspendSpawn: Bool = false) {
        self.error = error
        self.suspendSpawn = suspendSpawn
    }

    func resumeSpawn() { spawnWaiter?.resume(); spawnWaiter = nil }

    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent {
        requests.append(request)
        if suspendSpawn { await withCheckedContinuation { spawnWaiter = $0 } }
        if let error { throw error }
        return LeoAgent(
            name: Self.spawnedName, template: request.template, repo: request.repo, workspace: nil, branch: request.branch,
            canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }
    func listAgents() async throws -> [LeoAgent] { [] }
    func start(_ name: String) async throws {}
    func stop(_ name: String, wakeOnMessage: Bool?) async throws {}
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_ name: String) async throws {}
    func setTemplate(_ name: String, template: String) async throws {}
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws {}
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_ name: String, lines: Int?) async throws -> String { "" }
}
