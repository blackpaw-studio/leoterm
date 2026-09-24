import Foundation
import Testing
@testable import Ghostty

@MainActor struct LeoAgentActionsTests {
    @Test func actionsRefreshOnceAndForwardArguments() async {
        let daemon = ActionDaemon()
        let model = LeoSidebarModel()
        var refreshes = 0
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: model, hostSelection: .isolatedForTesting(), refresh: { refreshes += 1 })
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
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: model, hostSelection: .isolatedForTesting(), refresh: { refreshes += 1 })
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
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), refresh: {})
        var attached: LeoAgentRow?
        actions.spawn(.init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), attach: { row, _ in attached = row }, dismiss: {}, failure: { _ in })
        await awaitCondition { await MainActor.run { attached != nil } }
        #expect(attached?.name == "alpha")
    }

    @Test func spawnModelIgnoresReentrantSubmits() async {
        let daemon = ActionDaemon(suspendSpawn: true)
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: sidebar, hostSelection: .isolatedForTesting(), refresh: {})
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
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: sidebar, hostSelection: .isolatedForTesting(), refresh: {})
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
        let actions = LeoAgentActions(daemon: daemon, cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), refresh: {})
        let row = testRow()
        actions.start(row); actions.start(row)
        await awaitCondition { await daemon.calls == ["start:alpha"] }
        await daemon.resumeStart()
    }

    @Test func deletePlanAndTemplateCache() async throws {
        let daemon = ActionDaemon()
        let cli = testCLI(templates: ["one"])
        let model = LeoSidebarModel()
        let actions = LeoAgentActions(daemon: daemon, cli: cli, model: model, hostSelection: .isolatedForTesting(), refresh: {})
        #expect(try await actions.templates().map(\.name) == ["one"])
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
        let suiteDefaults = LeoInMemoryDefaults()
        let workConfiguration = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
        if let data = try? JSONEncoder().encode([workConfiguration]) { suiteDefaults.set(data, forKey: LeoHostStore.key) }
        let selection = LeoHostSelection.isolatedForTesting(defaults: suiteDefaults)
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

    /// A `templates()` call for host A that's still mid-fetch when the
    /// selection moves to host B must never leave B's cache entry
    /// contaminated with A's (now-stale) result once A's fetch finally
    /// completes.
    @Test func hostSwitchDuringInFlightTemplatesFetchNeverLeaksTheOldHostsTemplates() async throws {
        let daemon = ActionDaemon()
        let suiteDefaults = LeoInMemoryDefaults()
        let workConfiguration = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
        if let data = try? JSONEncoder().encode([workConfiguration]) { suiteDefaults.set(data, forKey: LeoHostStore.key) }
        let selection = LeoHostSelection.isolatedForTesting(defaults: suiteDefaults)
        await selection.start(flavor: .socketEvents)
        let gatedRunner = GatedTemplateRunner()
        let cli = LeoCLI(executableOverride: "/leo", runner: gatedRunner, isExecutable: { _ in true })
        let remoteRunner = TemplateSSHRunner()
        let actions = LeoAgentActions(
            daemon: daemon, cli: cli, model: LeoSidebarModel(),
            hostSelection: selection, processRunner: remoteRunner, refresh: {}
        )

        async let localTemplates = actions.templates()
        await gatedRunner.waitForCalls(1)

        selection.select(.remote("work"))
        #expect(try await actions.templates().map(\.name) == ["work-template"])

        await gatedRunner.resume()
        #expect(try await localTemplates.map(\.name) == ["local-template"])

        // A's delayed completion must not have overwritten B's cache entry.
        #expect(try await actions.templates().map(\.name) == ["work-template"])
        let remoteCalls = await remoteRunner.calls
        #expect(remoteCalls.count == 1, "the second read of the still-selected remote host must be served from cache")
    }

    /// Actions capture `daemon` and the selection's `generationToken`
    /// synchronously at invocation, not at execution: a request already in
    /// flight against host A's socket must never be silently redirected to
    /// B's, and its completion (refresh) must be dropped once the selection
    /// has moved on.
    @Test func actionCapturesDaemonAtInvocationAndDropsStaleCompletionAfterASelectionChange() async throws {
        let daemonA = GatedActionDaemon()
        let suiteDefaults = LeoInMemoryDefaults()
        let selection = LeoHostSelection.isolatedForTesting(defaults: suiteDefaults)
        await selection.start(flavor: .socketEvents)
        var refreshes = 0
        let actions = LeoAgentActions(daemon: daemonA, cli: testCLI(), model: LeoSidebarModel(), hostSelection: selection, refresh: { refreshes += 1 })
        let row = testRow()

        actions.stop(row)
        await awaitCondition { await daemonA.stopCallCount == 1 }

        // The selection moves on (to an unconfigured remote host, which
        // fails synchronously but still bumps the generation) WHILE the
        // stop request against A is still in flight. `updateDaemon` is not
        // called here on purpose: the point is that `run()` already
        // captured `daemonA` before this happened, so the in-flight request
        // stays bound to it regardless.
        selection.select(.remote("unconfigured"))

        await daemonA.release()
        for _ in 0..<50 { await Task.yield() }

        #expect(await daemonA.stopCallCount == 1, "the captured daemon must be the one that actually received the request")
        #expect(refreshes == 0, "a stale completion after the selection moved on must not trigger a refresh")
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

private actor GatedActionDaemon: LeoDaemonClient {
    private(set) var stopCallCount = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func stop(_ name: String, wakeOnMessage: Bool?) async throws {
        stopCallCount += 1
        await withCheckedContinuation { waiter = $0 }
    }

    func release() { waiter?.resume(); waiter = nil }

    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}

private actor TemplateSSHRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments))
        return LeoProcessResult(stdout: Data(#"[{"name":"work-template"}]"#.utf8), stderr: Data(), status: 0)
    }
}

/// A `LeoProcessRunning` for the local CLI's template fetch that suspends
/// until `resume()` is called, so a test can hold a `templates()` fetch
/// in flight while switching hosts out from under it.
private actor GatedTemplateRunner: LeoProcessRunning {
    private(set) var callCount = 0
    private var suspended = true
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func run(executable _: String, arguments _: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        callCount += 1
        if suspended { await withCheckedContinuation { continuations.append($0) } }
        return LeoProcessResult(stdout: Data(#"[{"name":"local-template"}]"#.utf8), stderr: Data(), status: 0)
    }

    func waitForCalls(_ expected: Int) async {
        while callCount < expected { await Task.yield() }
    }

    func resume() {
        suspended = false
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

private struct ActionRunner: LeoProcessRunning {
    let data: Data
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
        LeoProcessResult(stdout: data, stderr: Data(), status: 0)
    }
}

@MainActor private final class PlanBox {
    var value: LeoDeletePlan?
}
