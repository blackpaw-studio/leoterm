import Combine
import Foundation
import Testing
@testable import Ghostty
@testable import LeoKit

/// B-054: one published template list per machine on `LeoAgentActions`,
/// prefetched when the machine connects and read by both the New Agent sheet
/// and a row's Set Template submenu. Machines connect at once, so one
/// machine's list is never shown for, or blanked by, another.
@MainActor struct LeoTemplateListTests {
    private static let work = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
    private static let workHost = LeoHostID.remote("work")

    @Test func connectingAMachinePrefetchesItsPublishedListWithoutAnyReader() async {
        let fixture = Fixture()

        fixture.actions.hostConnected(.local)

        await awaitCondition(message: "the local list never landed") { await fixture.names(.local) == ["local-template"] }
    }

    @Test func spawnModelListsTheRemoteMachinesTemplatesNotTheLocalCLIs() async {
        let fixture = Fixture()
        let spawn = SpawnAgentModel(templateList: fixture.list(Self.workHost))

        fixture.actions.loadTemplates(for: Self.workHost)

        await awaitCondition(message: "the sheet never listed the remote templates") {
            await MainActor.run { spawn.templates.map(\.name) == ["work-template"] }
        }
        #expect(await fixture.remote.callCount == 1)
    }

    @Test func loadingOneMachineNeverBlanksOrChangesAnothersList() async {
        let fixture = Fixture()
        fixture.actions.loadTemplates(for: .local)
        await awaitCondition { await fixture.names(.local) == ["local-template"] }
        let localHistory = Recorder(fixture.list(.local))

        fixture.actions.loadTemplates(for: Self.workHost)

        #expect(fixture.actions.templateList(for: Self.workHost) == .loading)
        #expect(fixture.actions.templateList(for: .local) == .loaded([LeoTemplate(name: "local-template")]), "A's list stays while B loads")
        await awaitCondition { await fixture.names(Self.workHost) == ["work-template"] }
        #expect(localHistory.values == [.loaded([LeoTemplate(name: "local-template")])])
        #expect(await fixture.names(.local) == ["local-template"])
    }

    /// A fetch for A still in flight when B's list lands must neither delay
    /// nor overwrite it.
    @Test func aSlowFetchForOneMachineNeverLandsInAnotherMachinesList() async {
        let fixture = Fixture(gateLocal: true)
        fixture.actions.loadTemplates(for: .local)
        await fixture.local.waitForCalls(1)

        fixture.actions.loadTemplates(for: Self.workHost)
        await awaitCondition { await fixture.names(Self.workHost) == ["work-template"] }
        let workHistory = Recorder(fixture.list(Self.workHost))
        await fixture.local.resume()
        await awaitCondition { await fixture.names(.local) == ["local-template"] }

        #expect(fixture.actions.templateList(for: Self.workHost) == .loaded([LeoTemplate(name: "work-template")]))
        #expect(workHistory.values == [.loaded([LeoTemplate(name: "work-template")])])
    }

    @Test func aFailedFetchPublishesTheErrorAndTheSpawnModelSurfacesIt() async {
        let fixture = Fixture(remoteStatus: 255)
        let spawn = SpawnAgentModel(templateList: fixture.list(Self.workHost))

        fixture.actions.loadTemplates(for: Self.workHost)

        await awaitCondition {
            await MainActor.run { if case .failed = fixture.actions.templateList(for: Self.workHost) { true } else { false } }
        }
        #expect(spawn.templates.isEmpty)
        #expect(spawn.templateError?.contains("Permission denied") == true)
    }

    /// A user-initiated sidebar refresh re-reads every loaded machine's
    /// templates into its published list, without blanking it meanwhile.
    @Test func manualRefreshRefetchesEveryLoadedMachinesList() async {
        let fixture = Fixture()
        fixture.actions.loadTemplates(for: Self.workHost)
        fixture.actions.loadTemplates(for: .local)
        await awaitCondition { await fixture.names(Self.workHost) == ["work-template"] }
        await awaitCondition { await fixture.names(.local) == ["local-template"] }
        let history = Recorder(fixture.list(Self.workHost))

        fixture.actions.invalidateTemplateCache()

        await awaitCondition { await fixture.remote.callCount == 2 }
        await awaitCondition { await fixture.local.callCount == 2 }
        #expect(!history.values.contains(.loading))
    }

    // MARK: Fixture

    @MainActor private final class Fixture {
        let actions: LeoAgentActions
        let local: GatedTemplateProcess
        let remote: GatedTemplateProcess

        init(gateLocal: Bool = false, remoteStatus: Int32 = 0) {
            local = GatedTemplateProcess(name: "local-template", gated: gateLocal)
            remote = GatedTemplateProcess(name: "work-template", gated: false, status: remoteStatus)
            actions = LeoAgentActions(
                clients: FakeMachineClients(
                    daemons: [.local: NoTemplateDaemon(), LeoTemplateListTests.workHost: NoTemplateDaemon()],
                    configurations: [LeoTemplateListTests.work]
                ),
                cli: LeoCLI(executableOverride: "/leo", runner: local, isExecutable: { _ in true }),
                model: LeoSidebarModel(), processRunner: remote, refresh: {}
            )
        }

        func list(_ host: LeoHostID) -> AnyPublisher<LeoTemplateListState, Never> {
            actions.$templateLists.map { $0[host] ?? .loading }.removeDuplicates().eraseToAnyPublisher()
        }

        func names(_ host: LeoHostID) -> [String]? {
            if case .loaded(let templates) = actions.templateList(for: host) { return templates.map(\.name) }
            return nil
        }
    }

    @MainActor private final class Recorder {
        private(set) var values: [LeoTemplateListState] = []
        private var cancellable: AnyCancellable?
        init(_ publisher: AnyPublisher<LeoTemplateListState, Never>) {
            cancellable = publisher.sink { [weak self] in self?.values.append($0) }
        }
    }
}

/// Answers `leo template list --json` (local CLI or ssh exec alike) with one
/// named template, optionally holding every call until `resume()`.
private actor GatedTemplateProcess: LeoProcessRunning {
    private(set) var callCount = 0
    private let name: String
    private let status: Int32
    private var gated: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(name: String, gated: Bool, status: Int32 = 0) {
        self.name = name
        self.gated = gated
        self.status = status
    }

    func run(executable _: String, arguments _: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        callCount += 1
        if gated { await withCheckedContinuation { continuations.append($0) } }
        guard status == 0 else {
            return LeoProcessResult(stdout: Data(), stderr: Data("Permission denied (publickey).".utf8), status: status)
        }
        return LeoProcessResult(stdout: Data(#"[{"name":"\#(name)"}]"#.utf8), stderr: Data(), status: 0)
    }

    func waitForCalls(_ expected: Int) async {
        while callCount < expected { await Task.yield() }
    }

    func resume() {
        gated = false
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

private struct NoTemplateDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
