import Combine
import Foundation
import Testing
@testable import Ghostty

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

    @Test func worktreeModelFailsWhenHostChanges() {
        let host = CurrentValueSubject<LeoHostID, Never>(.local)
        let model = worktreeModel(source: sourceRow(host: .local), selectedHost: host.eraseToAnyPublisher())
        model.branch = "feat/x"
        #expect(model.validationError == nil)
        host.send(.remote("work"))
        #expect(model.hostMismatch(selected: .remote("work")) != nil)
        #expect(model.validationError == model.hostMismatch(selected: .remote("work")))
        host.send(.local)
        #expect(model.validationError == nil)
    }

    /// A plain New Agent sheet has no source, so a host switch never blocks it.
    @Test func plainModelIgnoresHostChanges() {
        let model = worktreeModel(source: nil)
        #expect(!model.isWorktree)
        #expect(model.hostMismatch(selected: .remote("work")) == nil)
    }

    @Test func worktreeSpawnLocalSendsBranchAndSelectsRow() async throws {
        let daemon = WorktreeDaemon()
        let selection = LeoHostSelection.isolatedForTesting()
        await selection.start(flavor: .socketEvents)
        try await spawnAndSelect(daemon: daemon, selection: selection, host: .local)
    }

    @Test func worktreeSpawnRemoteRunsOnRemoteHostAndSelectsRow() async throws {
        let localDaemon = WorktreeDaemon()
        let remoteDaemon = WorktreeDaemon()
        let selection = LeoHostSelection.isolatedForTesting()
        await selection.start(flavor: .socketEvents)
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(daemon: localDaemon, cli: worktreeCLI(), model: sidebar, hostSelection: selection, refresh: {})
        // No configuration for "work": the selection fails fast instead of
        // exec'ing a real ssh; LeoRuntime would hand actions the tunnel's
        // daemon, which the fake stands in for.
        selection.select(.remote("work"))
        actions.updateDaemon(remoteDaemon)
        try await spawnAndSelect(daemon: remoteDaemon, sidebar: sidebar, actions: actions, host: .remote("work"))
        #expect(await localDaemon.requests.isEmpty)
    }

    @Test func worktreeSpawnFailureKeepsSheetAndShowsError() async {
        let daemon = WorktreeDaemon(error: .daemon(code: "x", message: "branch exists", matches: []))
        let actions = LeoAgentActions(
            daemon: daemon, cli: worktreeCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), refresh: {})
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

    // MARK: - Helpers

    private func spawnAndSelect(daemon: WorktreeDaemon, selection: LeoHostSelection, host: LeoHostID) async throws {
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(daemon: daemon, cli: worktreeCLI(), model: sidebar, hostSelection: selection, refresh: {})
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

    private func worktreeModel(
        source: LeoAgentRow?, selectedHost: AnyPublisher<LeoHostID, Never> = Empty().eraseToAnyPublisher()
    ) -> SpawnAgentModel {
        let list = Just(LeoTemplateListState.loaded([LeoTemplate(name: "claude")])).eraseToAnyPublisher()
        return SpawnAgentModel(templateList: list, source: source, selectedHost: selectedHost)
    }

    private func worktreeCLI() -> LeoCLI {
        LeoCLI(executableOverride: "/leo", runner: WorktreeRunner(), isExecutable: { _ in true })
    }
}

/// Records every spawn request and answers with the agent the daemon would
/// create for a worktree spawn.
private actor WorktreeDaemon: LeoDaemonClient {
    static let spawnedName = "r-feat-x"
    private(set) var requests: [LeoSpawnRequest] = []
    private let error: LeoDaemonError?

    init(error: LeoDaemonError? = nil) { self.error = error }

    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent {
        requests.append(request)
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

private struct WorktreeRunner: LeoProcessRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
        LeoProcessResult(stdout: Data(#"[{"name":"claude"}]"#.utf8), stderr: Data(), status: 0)
    }
}
