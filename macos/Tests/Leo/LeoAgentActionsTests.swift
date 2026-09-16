import Foundation
import Testing
@testable import Ghostty

@MainActor struct LeoAgentActionsTests {
    @Test func actionsRefreshOnceAndForwardArguments() async {
        let daemon = ActionDaemon()
        let model = LeoSidebarModel()
        var refreshes = 0
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: model, refresh: { refreshes += 1 })
        let row = testRow()
        actions.start(row)
        await awaitCondition { await daemon.calls == ["start:alpha"] }
        #expect(refreshes == 1)
        actions.stop(row)
        await awaitCondition { await daemon.calls.contains("stop:alpha") }
        actions.restart(row)
        await awaitCondition { await daemon.calls.contains("restart:alpha") }
        actions.setTemplate(row, template: "swift")
        await awaitCondition { await daemon.calls.contains("template:alpha:swift") }
        actions.rename(row, newName: "bravo")
        await awaitCondition { await daemon.calls.contains("rename:alpha:bravo") }
        actions.delete(row, force: true, deleteBranch: true)
        await awaitCondition { await daemon.calls.contains("delete:alpha:true:true") }
        #expect(refreshes == 6)
    }

    @Test func rowErrorsPersistUntilSuccessfulListRefresh() async {
        let daemon = ActionDaemon(error: .daemon(code: "bad", message: "nope", matches: []))
        let model = LeoSidebarModel()
        var refreshes = 0
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: model, refresh: { refreshes += 1 })
        let row = testRow()
        actions.restart(row)
        await awaitCondition { await MainActor.run { model.rowErrors[row.id] == "nope" } }
        #expect(refreshes == 0)
        model.receive(LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: 1, listRefreshSucceeded: false))
        #expect(model.rowErrors[row.id] == "nope")
        model.receive(LeoSidebarSnapshot(rows: [row], connectivity: .failed(message: "offline"), generation: 2))
        #expect(model.rowErrors[row.id] == "nope")
        model.receive(LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: 3, listRefreshSucceeded: true))
        #expect(model.rowErrors.isEmpty)
    }

    @Test func spawnAttachesNewRow() async {
        let daemon = ActionDaemon()
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: LeoSidebarModel(), refresh: {})
        var attached: LeoAgentRow?
        actions.spawn(.init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), attach: { row, _ in attached = row }, dismiss: {}, failure: { _ in })
        await awaitCondition { await MainActor.run { attached != nil } }
        #expect(attached?.name == "alpha")
    }

    @Test func spawnModelIgnoresReentrantSubmits() async {
        let daemon = ActionDaemon(suspendSpawn: true)
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: sidebar, refresh: {})
        let model = SpawnAgentModel(cli: testCLI())
        let request = LeoSpawnRequest(template: "default", repo: "", name: nil, branch: nil, prompt: nil)

        model.spawn(request, actions: actions, attach: { _, _ in }, dismiss: {})
        model.spawn(request, actions: actions, attach: { _, _ in }, dismiss: {})

        await awaitCondition { await daemon.calls == ["spawn"] }
        #expect(model.isSpawning)
        await daemon.resumeSpawn()
        await awaitCondition { await MainActor.run { !model.isSpawning } }
    }

    @Test func successfulSpawnInvokesSidebarAttachRequest() async {
        let daemon = ActionDaemon()
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: sidebar, refresh: {})
        let model = SpawnAgentModel(cli: testCLI())
        var attached: LeoAgentRow?
        sidebar.attachRequested = { row, _, _ in attached = row }

        model.spawn(.init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), actions: actions, attach: { row, disposition in
            sidebar.attachRequested(row, LeoWindowID(), disposition)
        }, dismiss: {})

        await awaitCondition { await MainActor.run { attached != nil } }
        #expect(attached?.name == "alpha")
    }

    @Test func duplicatePendingActionIsIgnored() async {
        let daemon = ActionDaemon(suspendStart: true)
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: LeoSidebarModel(), refresh: {})
        let row = testRow()
        actions.start(row); actions.start(row)
        await awaitCondition { await daemon.calls == ["start:alpha"] }
        await daemon.resumeStart()
    }

    @Test func deletePlanAndTemplateCache() async throws {
        let daemon = ActionDaemon()
        let cli = testCLI(templates: ["one"])
        let model = LeoSidebarModel()
        let clock = ActionClock()
        let actions = LeoAgentActions(daemon: daemon, cli: cli, model: model, refresh: {}, clock: { clock.now })
        #expect(try await actions.templates().map(\.name) == ["one"])
        #expect(try await actions.templates().map(\.name) == ["one"])
        clock.now = clock.now.addingTimeInterval(61)
        #expect(try await actions.templates().map(\.name) == ["one"])
        let row = testRow()
        let box = PlanBox()
        actions.deletePlan(row) { box.value = $0 }
        await awaitCondition { await MainActor.run { box.value != nil } }
        #expect(box.value?.branch == "branch")
    }

    /// Local templates come from the CLI; a remote host's templates come
    /// from a one-off `ssh ... leo template list --json` exec, scoped to
    /// its own cache entry.
    @Test func templateCacheIsScopedToSelectedHost() async throws {
        let daemon = ActionDaemon()
        let suiteDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let workConfiguration = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
        if let data = try? JSONEncoder().encode([workConfiguration]) { suiteDefaults.set(data, forKey: LeoHostStore.key) }
        let selection = LeoHostSelection(store: LeoHostStore(defaults: suiteDefaults), defaults: suiteDefaults)
        await selection.start(flavor: .socketEvents)
        let runner = TemplateSSHRunner()
        let actions = LeoAgentActions(
            daemon: daemon, cli: testCLI(templates: ["local-template"]), model: LeoSidebarModel(),
            hostSelection: selection, processRunner: runner, refresh: {}
        )

        #expect(try await actions.templates().map(\.name) == ["local-template"])
        selection.select(.remote("work"))
        #expect(try await actions.templates().map(\.name) == ["work-template"])

        let calls = await runner.calls
        #expect(calls.count == 1)
        let expectedArguments = try LeoSSHCommand(configuration: workConfiguration).execArguments(
            remoteCommand: [workConfiguration.remoteLeoPath, "template", "list", "--json"]
        )
        #expect(calls.first?.arguments == expectedArguments)
    }

    private func testRow() -> LeoAgentRow {
        LeoAgentRow(host: .local, name: "alpha", template: "default", status: .running, activity: .unknown, actionDetail: nil)
    }

    private func testCLI(templates: [String] = []) -> LeoCLI {
        let objects = templates.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
        let payload = Data("[\(objects)]".utf8)
        return LeoCLI(executableOverride: "/leo", runner: ActionRunner(data: payload), isExecutable: { _ in true })
    }
}

private actor ActionDaemon: LeoDaemonClient {
    private(set) var calls: [String] = []
    private let error: LeoDaemonError?
    private let suspendStart: Bool
    private let suspendSpawn: Bool
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var spawnWaiter: CheckedContinuation<Void, Never>?

    init(error: LeoDaemonError? = nil, suspendStart: Bool = false, suspendSpawn: Bool = false) {
        self.error = error
        self.suspendStart = suspendStart
        self.suspendSpawn = suspendSpawn
    }
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent {
        calls.append("spawn")
        if suspendSpawn { await withCheckedContinuation { spawnWaiter = $0 } }
        try fail()
        return agent
    }
    func start(_ name: String) async throws { calls.append("start:\(name)"); if suspendStart { await withCheckedContinuation { startWaiter = $0 } }; try fail() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { calls.append("stop:\(name)"); try fail() }
    func restart(_ name: String) async throws -> LeoAgent { calls.append("restart:\(name)"); try fail(); return agent }
    func reset(_ name: String) async throws { try fail() }
    func setTemplate(_ name: String, template: String) async throws { calls.append("template:\(name):\(template)"); try fail() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { calls.append("rename:\(name):\(newName)"); try fail(); return agent }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { calls.append("delete:\(name):\(force ?? false):\(deleteBranch ?? false)"); try fail() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { calls.append("plan:\(name)"); try fail(); return LeoDeletePlan(name: name, hasWorktree: true, branch: "branch", worktreePath: "/work") }
    func logs(_ name: String, lines: Int?) async throws -> String { "" }
    func resumeStart() { startWaiter?.resume(); startWaiter = nil }
    func resumeSpawn() { spawnWaiter?.resume(); spawnWaiter = nil }
    private func fail() throws { if let error { throw error } }
    private var agent: LeoAgent { LeoAgent(name: "alpha", template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil) }
}

private actor TemplateSSHRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments))
        return LeoProcessResult(stdout: Data(#"[{"name":"work-template"}]"#.utf8), stderr: Data(), status: 0)
    }
}

private struct ActionRunner: LeoProcessRunning {
    let data: Data
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
        LeoProcessResult(stdout: data, stderr: Data(), status: 0)
    }
}

private final class ActionClock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)
}

@MainActor private final class PlanBox {
    var value: LeoDeletePlan?
}
