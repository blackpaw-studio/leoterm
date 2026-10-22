import Combine
import Foundation
import Testing
@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoAgentActionsTests {
    @Test func actionsRefreshOnceAndForwardArguments() async {
        let daemon = ActionDaemon()
        let model = LeoSidebarModel()
        var refreshes = 0
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: testCLI(), model: model, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: { refreshes += 1 })
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

    /// B-274: Delete asks about the agent's unsaved panes first; Cancel
    /// leaves the agent alone.
    @Test func deleteAsksAboutTheAgentsPanesFirst() async {
        let daemon = ActionDaemon()
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: daemon), cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(),
            processRunner: LeoRecordingTemplateRunner(), refresh: {})
        let row = testRow()
        var asked: [String] = []
        actions.closePanes = { row in
            asked.append(row.name)
            return asked.count > 1
        }

        actions.delete(row, force: false, deleteBranch: false)
        await awaitCondition { await MainActor.run { asked.count == 1 } }
        actions.restart(row)
        await awaitCondition { await daemon.calls.contains("restart:alpha") }
        #expect(await !daemon.calls.contains { $0.hasPrefix("delete") }, "Cancel stops the delete")

        actions.delete(row, force: false, deleteBranch: false)
        await awaitCondition { await daemon.calls.contains("delete:alpha:false:false") }
        #expect(asked == ["alpha", "alpha"])
    }

    /// B-049: the start prompt attaches only after the daemon accepted the
    /// start; a refusal shows on the row as before.
    @Test func startReportsWhetherTheDaemonAcceptedIt() async {
        let model = LeoSidebarModel()
        let row = testRow()
        var results: [Bool] = []
        let accepting = LeoAgentActions(clients: FakeMachineClients(daemon: ActionDaemon()), cli: testCLI(), model: model, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        accepting.start(row) { results.append($0) }
        await awaitCondition { await MainActor.run { results == [true] } }

        let refusing = LeoAgentActions(
            clients: FakeMachineClients(daemon: ActionDaemon(error: .daemon(code: "bad", message: "nope", matches: []))), cli: testCLI(), model: model,
            hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        refusing.start(row) { results.append($0) }
        await awaitCondition { await MainActor.run { results == [true, false] } }

        #expect(results == [true, false])
        #expect(model.rowErrors[row.id] == "nope")
    }

    @Test func rowErrorsPersistUntilSuccessfulListRefresh() async {
        let daemon = ActionDaemon(error: .daemon(code: "bad", message: "nope", matches: []))
        let model = LeoSidebarModel()
        var refreshes = 0
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: testCLI(), model: model, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: { refreshes += 1 })
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
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        var attached: LeoAgentRow?
        actions.spawn(.init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: .local, attach: { row, _ in attached = row }, dismiss: {}, failure: { _ in })
        await awaitCondition { await MainActor.run { attached != nil } }
        #expect(attached?.name == "alpha")
    }

    private static let claudeNotFound = LeoDaemonError.daemon(
        code: "claude_not_found", message: "claude not found on PATH (/usr/bin:/bin)", matches: []
    )

    @Test func aSpawnThatFailsWithClaudeNotFoundLeadsToTheOnboardingOffer() async {
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: ActionDaemon(error: Self.claudeNotFound)), cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        var offers = 0
        var failures: [String] = []
        actions.claudeNotFound = { offers += 1 }

        actions.spawn(.init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: .local, attach: { _, _ in }, dismiss: {}, failure: { failures.append($0) })

        await awaitCondition { await MainActor.run { failures.count == 1 } }
        #expect(offers == 1)
        #expect(failures == [LeoAgentActions.claudeMissingMessage(on: .local)])
    }

    @Test func aStartThatFailsWithClaudeNotFoundLeadsToTheOnboardingOffer() async {
        let model = LeoSidebarModel()
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: ActionDaemon(error: Self.claudeNotFound)), cli: testCLI(), model: model, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        var offers = 0
        actions.claudeNotFound = { offers += 1 }
        let row = testRow()

        actions.start(row)

        await awaitCondition { await MainActor.run { model.rowErrors[row.id] != nil } }
        #expect(offers == 1)
        #expect(model.rowErrors[row.id] == LeoAgentActions.claudeMissingMessage(on: .local))
    }

    @Test func aRemoteSpawnThatFailsWithClaudeNotFoundNamesTheHostAndOffersNoLocalInstall() async {
        let remote = LeoHostID.remote("work")
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: ActionDaemon(error: Self.claudeNotFound), host: remote), cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        var offers = 0
        var failures: [String] = []
        actions.claudeNotFound = { offers += 1 }

        actions.spawn(.init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: remote, attach: { _, _ in }, dismiss: {}, failure: { failures.append($0) })

        await awaitCondition { await MainActor.run { failures.count == 1 } }
        #expect(offers == 0)
        #expect(failures == ["Claude Code isn’t installed on work. Install it there, then try again."])
        #expect(!failures[0].contains("Set Up Claude"))
    }

    @Test func aRemoteStartThatFailsWithClaudeNotFoundNamesTheHostAndOffersNoLocalInstall() async {
        let model = LeoSidebarModel()
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: ActionDaemon(error: Self.claudeNotFound), host: .remote("work")), cli: testCLI(), model: model, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        var offers = 0
        actions.claudeNotFound = { offers += 1 }
        let row = LeoAgentRow(host: .remote("work"), name: "alpha", template: "default", status: .running, activity: .unknown, actionDetail: nil)

        actions.start(row)

        await awaitCondition { await MainActor.run { model.rowErrors[row.id] != nil } }
        #expect(offers == 0)
        #expect(model.rowErrors[row.id] == "Claude Code isn’t installed on work. Install it there, then try again.")
    }

    @Test func otherSpawnFailuresStayAsTheyWereAndOfferNothing() async {
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: ActionDaemon(error: .daemon(code: "bad", message: "nope", matches: []))), cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        var offers = 0
        var failures: [String] = []
        actions.claudeNotFound = { offers += 1 }

        actions.spawn(.init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: .local, attach: { _, _ in }, dismiss: {}, failure: { failures.append($0) })

        await awaitCondition { await MainActor.run { failures.count == 1 } }
        #expect(offers == 0)
        #expect(failures == ["nope"])
    }

    @Test func spawnModelIgnoresReentrantSubmits() async {
        let daemon = ActionDaemon(suspendSpawn: true)
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: testCLI(), model: sidebar, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        let model = SpawnAgentModel(templateList: Just(.loading).eraseToAnyPublisher())
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
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: testCLI(), model: sidebar, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        let model = SpawnAgentModel(templateList: Just(.loading).eraseToAnyPublisher())
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
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        let row = testRow()
        actions.start(row); actions.start(row)
        await awaitCondition { await daemon.calls == ["start:alpha"] }
        await daemon.resumeStart()
    }

    @Test func deletePlanAndTemplateCache() async throws {
        let daemon = ActionDaemon()
        let cli = testCLI(templates: ["one"])
        let model = LeoSidebarModel()
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: daemon), cli: cli, model: model, hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        #expect(try await actions.templates(for: .local).map(\.name) == ["one"])
        #expect(try await actions.templates(for: .local).map(\.name) == ["one"])
        let row = testRow()
        let box = PlanBox()
        actions.deletePlan(row) { box.value = $0 }
        await awaitCondition { await MainActor.run { box.value != nil } }
        #expect(box.value?.branch == "branch")
    }

    /// Local templates come from the CLI; a remote host's templates come
    /// from a one-off `ssh ... leo template list --json` exec, each cached
    /// in its own slot so reading one never evicts the other.
    @Test func templateCacheIsScopedToTheHostItIsReadFor() async throws {
        let daemon = ActionDaemon()
        let workConfiguration = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
        let runner = LeoRecordingTemplateRunner(templates: ["work-template"])
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemons: [.local: daemon], configurations: [workConfiguration]),
            cli: testCLI(templates: ["local-template"]), model: LeoSidebarModel(),
            hostSelection: .isolatedForTesting(), processRunner: runner, refresh: {}
        )

        #expect(try await actions.templates(for: .local).map(\.name) == ["local-template"])
        #expect(try await actions.templates(for: .remote("work")).map(\.name) == ["work-template"])
        #expect(try await actions.templates(for: .local).map(\.name) == ["local-template"])
        #expect(try await actions.templates(for: .remote("work")).map(\.name) == ["work-template"])

        let calls = await runner.calls
        #expect(calls.count == 1, "each host is read once; the second reads are served from cache")
        let expectedArguments = try LeoSSHCommand(configuration: workConfiguration).execArguments(
            remoteCommand: [workConfiguration.remoteLeoPath, "template", "list", "--json"]
        )
        #expect(calls.first?.arguments == expectedArguments)
    }

    /// B-112: the shared fake answers exactly the templates it was built
    /// with (none by default) and records each exec it was handed.
    @Test func recordingTemplateRunnerAnswersItsConfiguredTemplates() async throws {
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
        let runner = LeoRecordingTemplateRunner(templates: ["a", "b"])
        let actions = LeoAgentActions(
            clients: FakeMachineClients(configurations: [configuration]), cli: .recordingForTests(), model: LeoSidebarModel(),
            hostSelection: .isolatedForTesting(), processRunner: runner, refresh: {}
        )

        #expect(try await actions.templates(for: .remote("work")).map(\.name) == ["a", "b"])
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.executable == "/usr/bin/ssh")

        let empty = try await LeoRecordingTemplateRunner().run(executable: "/leo", arguments: [], timeout: 1)
        #expect(try JSONDecoder().decode([LeoTemplate].self, from: empty.stdout).isEmpty)
    }

    /// A `templates(for:)` call for host A that's still mid-fetch while host
    /// B is read must never leave B's cache entry contaminated with A's
    /// (slow, now-stale) result once A's fetch finally completes.
    @Test func anInFlightTemplatesFetchNeverLeaksIntoAnotherHostsTemplates() async throws {
        let workConfiguration = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
        let gatedRunner = GatedTemplateRunner()
        let remoteRunner = LeoRecordingTemplateRunner(templates: ["work-template"])
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemons: [.local: ActionDaemon()], configurations: [workConfiguration]),
            cli: LeoCLI.recordingForTests(runner: gatedRunner), model: LeoSidebarModel(),
            hostSelection: .isolatedForTesting(), processRunner: remoteRunner, refresh: {}
        )

        async let localTemplates = actions.templates(for: .local)
        await gatedRunner.waitForCalls(1)

        #expect(try await actions.templates(for: .remote("work")).map(\.name) == ["work-template"])

        await gatedRunner.resume()
        #expect(try await localTemplates.map(\.name) == ["local-template"])

        // A's delayed completion must not have overwritten B's cache entry.
        #expect(try await actions.templates(for: .remote("work")).map(\.name) == ["work-template"])
        let remoteCalls = await remoteRunner.calls
        #expect(remoteCalls.count == 1, "the second read of the remote host must be served from cache")
    }

    /// Actions capture the row's daemon and its host's generation
    /// synchronously at invocation, not at execution: a request already in
    /// flight against A's socket must never be silently redirected to a
    /// replacement connection, and its completion (refresh) must be dropped
    /// once A reconnected.
    @Test func actionCapturesDaemonAtInvocationAndDropsStaleCompletionAfterAReconnect() async throws {
        let daemonA = GatedActionDaemon()
        let replacement = GatedActionDaemon()
        let clients = FakeMachineClients(daemon: daemonA)
        var refreshes = 0
        let actions = LeoAgentActions(clients: clients, cli: testCLI(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: { refreshes += 1 })
        let row = testRow()

        actions.stop(row)
        await awaitCondition { await daemonA.stopCallCount == 1 }

        // A reconnects WHILE the stop request against its old connection is
        // still in flight: `run()` already captured `daemonA`, so the
        // in-flight request stays bound to it regardless.
        clients.connect(.local, replacement)

        await daemonA.release()
        for _ in 0..<50 { await Task.yield() }

        #expect(await daemonA.stopCallCount == 1, "the captured daemon must be the one that actually received the request")
        #expect(await replacement.stopCallCount == 0)
        #expect(refreshes == 0, "a stale completion after the machine reconnected must not trigger a refresh")
    }

    private func testRow() -> LeoAgentRow {
        LeoAgentRow(host: .local, name: "alpha", template: "default", status: .running, activity: .unknown, actionDetail: nil)
    }

    private func testCLI(templates: [String] = []) -> LeoCLI {
        .recordingForTests(templates: templates)
    }
}

/// Machines connect at once: every action resolves its own row's host, so
/// one machine reconnecting, failing or bumping its generation never touches
/// another's requests.
@MainActor struct LeoMachineActionsTests {
    private let work = LeoHostID.remote("work")

    private func actions(_ clients: FakeMachineClients, refresh: @escaping () -> Void = {}) -> LeoAgentActions {
        LeoAgentActions(
            clients: clients, cli: .recordingForTests(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(),
            processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: refresh)
    }

    private func row(on host: LeoHostID) -> LeoAgentRow {
        LeoAgentRow(host: host, name: "alpha", template: "default", status: .running, activity: .unknown, actionDetail: nil)
    }

    @Test func anActionOnBsRowReachesBsClientWhileAIsReconnecting() async {
        let local = ActionDaemon()
        let remote = ActionDaemon()
        let clients = FakeMachineClients(daemons: [.local: local, work: remote])
        let model = LeoSidebarModel()
        let actions = LeoAgentActions(
            clients: clients, cli: .recordingForTests(), model: model, hostSelection: .isolatedForTesting(),
            processRunner: LeoRecordingTemplateRunner(), refresh: {})
        clients.disconnect(.local)

        actions.stop(row(on: work))

        await awaitCondition { await remote.calls == ["stop:alpha"] }
        #expect(await local.calls.isEmpty)
        actions.stop(row(on: .local))
        await awaitCondition { await MainActor.run { model.rowErrors[row(on: .local).id] != nil } }
        #expect(model.rowErrors[row(on: .local).id] == "localhost isn't connected.")
        #expect(await local.calls.isEmpty)
    }

    @Test func anActionNeverReachesAnotherMachinesClient() async {
        let local = ActionDaemon()
        let remote = ActionDaemon()
        let actions = actions(FakeMachineClients(daemons: [.local: local, work: remote]))

        actions.restart(row(on: .local))
        await awaitCondition { await local.calls == ["restart:alpha"] }

        #expect(await remote.calls.isEmpty)
    }

    @Test func aGenerationBumpOnADoesNotDropBsCompletion() async {
        let remote = GatedActionDaemon()
        let clients = FakeMachineClients(daemons: [.local: ActionDaemon(), work: remote])
        var refreshes = 0
        let actions = actions(clients) { refreshes += 1 }

        actions.stop(row(on: work))
        await awaitCondition { await remote.stopCallCount == 1 }
        clients.connect(.local, ActionDaemon())
        await remote.release()

        await awaitCondition { await MainActor.run { refreshes == 1 } }
    }

    @Test func aGenerationBumpOnBStillDropsBsOwnStaleCompletion() async {
        let remote = GatedActionDaemon()
        let clients = FakeMachineClients(daemons: [work: remote])
        var refreshes = 0
        let actions = actions(clients) { refreshes += 1 }

        actions.stop(row(on: work))
        await awaitCondition { await remote.stopCallCount == 1 }
        clients.connect(work, ActionDaemon())
        await remote.release()
        for _ in 0..<50 { await Task.yield() }

        #expect(refreshes == 0)
    }

    @Test func spawnOnBSucceedsWhileAIsFailed() async {
        let remote = ActionDaemon()
        let clients = FakeMachineClients(daemons: [.local: ActionDaemon(), work: remote])
        clients.disconnect(.local)
        let actions = actions(clients)
        var attached: LeoAgentRow?
        var failures: [String] = []

        actions.spawn(
            .init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: work,
            attach: { row, _ in attached = row }, dismiss: {}, failure: { failures.append($0) })

        await awaitCondition { await MainActor.run { attached != nil } }
        #expect(attached?.host == work)
        #expect(failures.isEmpty)
        #expect(await remote.calls == ["spawn"])
    }

    @Test func spawnOnADisconnectedMachineIsRefusedWithoutARequest() async {
        let local = ActionDaemon()
        let clients = FakeMachineClients(daemons: [.local: local])
        let actions = actions(clients)
        var failures: [String] = []

        actions.spawn(
            .init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: work,
            attach: { _, _ in }, dismiss: {}, failure: { failures.append($0) })

        #expect(failures == ["Not connected to work yet"])
        #expect(await local.calls.isEmpty)
    }

    @Test func aSpawnWhoseMachineReconnectedMidFlightReportsItInsteadOfAttaching() async {
        let remote = ActionDaemon(suspendSpawn: true)
        let clients = FakeMachineClients(daemons: [work: remote])
        let actions = actions(clients)
        var attached = false
        var failures: [String] = []

        actions.spawn(
            .init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: work,
            attach: { _, _ in attached = true }, dismiss: {}, failure: { failures.append($0) })
        await awaitCondition { await remote.calls == ["spawn"] }
        clients.connect(work, ActionDaemon())
        await remote.resumeSpawn()

        await awaitCondition { await MainActor.run { failures.count == 1 } }
        #expect(!attached)
    }

    private func sshCalls(_ runner: LeoRecordingTemplateRunner, to target: String) async -> Int {
        await runner.calls.filter { $0.arguments.contains(target) }.count
    }

    @Test func aManualRefreshSkipsMachinesWithoutAConnection() async {
        let first = LeoHostConfiguration(name: "one", sshTarget: "evan@one")
        let second = LeoHostConfiguration(name: "two", sshTarget: "evan@two")
        let runner = LeoRecordingTemplateRunner(templates: ["t"])
        let clients = FakeMachineClients(
            daemons: [.remote("one"): ActionDaemon(), .remote("two"): ActionDaemon()], configurations: [first, second])
        let actions = LeoAgentActions(
            clients: clients, cli: .recordingForTests(), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(),
            processRunner: runner, refresh: {})
        actions.loadTemplates(for: .remote("one"))
        actions.loadTemplates(for: .remote("two"))
        await awaitCondition { await runner.calls.count == 2 }
        clients.disconnect(.remote("two"))

        actions.invalidateTemplateCache()

        await awaitCondition { await sshCalls(runner, to: "evan@one") == 2 }
        for _ in 0..<50 { await Task.yield() }
        #expect(await sshCalls(runner, to: "evan@two") == 1, "a machine with no client is not refetched")
    }

    @Test func aSlowMachineNeverHoldsUpAManualRefreshOfTheOthers() async {
        let configurations = ["one", "two", "three"].map { LeoHostConfiguration(name: $0, sshTarget: "evan@\($0)") }
        let gated = GatedTemplateRunner()
        let runner = LeoRecordingTemplateRunner(templates: ["t"])
        var daemons: [LeoHostID: any LeoDaemonClient] = [.local: ActionDaemon()]
        for configuration in configurations { daemons[.remote(configuration.name)] = ActionDaemon() }
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemons: daemons, configurations: configurations),
            cli: .recordingForTests(runner: gated), model: LeoSidebarModel(), hostSelection: .isolatedForTesting(),
            processRunner: runner, refresh: {})
        actions.loadTemplates(for: .local)
        await gated.waitForCalls(1)
        for configuration in configurations { actions.loadTemplates(for: .remote(configuration.name)) }
        await awaitCondition { await runner.calls.count == 3 }

        actions.invalidateTemplateCache()

        await awaitCondition(message: "the remotes never reloaded while the local fetch hung") { await runner.calls.count == 6 }
        await gated.resume()
    }

    @Test func theClaudeOnboardingOfferStaysLocalOnly() async {
        let missing = LeoDaemonError.daemon(code: "claude_not_found", message: "claude not found on PATH", matches: [])
        let clients = FakeMachineClients(daemons: [.local: ActionDaemon(), work: ActionDaemon(error: missing)])
        let actions = actions(clients)
        var offers = 0
        var failures: [String] = []
        actions.claudeNotFound = { offers += 1 }

        actions.spawn(
            .init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: work,
            attach: { _, _ in }, dismiss: {}, failure: { failures.append($0) })
        await awaitCondition { await MainActor.run { failures.count == 1 } }
        #expect(offers == 0, "a failure on a remote machine never opens the local install flow")

        clients.connect(.local, ActionDaemon(error: missing))
        actions.spawn(
            .init(template: "default", repo: "", name: nil, branch: nil, prompt: nil), on: .local,
            attach: { _, _ in }, dismiss: {}, failure: { failures.append($0) })
        await awaitCondition { await MainActor.run { offers == 1 } }
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

@MainActor private final class PlanBox {
    var value: LeoDeletePlan?
}
