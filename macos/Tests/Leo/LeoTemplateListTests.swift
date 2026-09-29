import Combine
import Foundation
import Testing
@testable import Ghostty

/// B-054: one published, host-aware template list on `LeoAgentActions`,
/// prefetched on every host selection and read by both the New Agent sheet
/// and a row's Set Template submenu.
@MainActor struct LeoTemplateListTests {
    private static let work = LeoHostConfiguration(name: "work", sshTarget: "evan@work")

    @Test func hostSelectionPrefetchesThePublishedListWithoutAnyReader() async throws {
        let fixture = try await Fixture()

        fixture.selection.select(.local)

        await awaitCondition(message: "the local list never landed") { await fixture.names() == ["local-template"] }
    }

    @Test func spawnModelListsTheRemoteHostsTemplatesNotTheLocalCLIs() async throws {
        let fixture = try await Fixture()
        let spawn = SpawnAgentModel(templateList: fixture.actions.$templateList.eraseToAnyPublisher())

        fixture.selection.select(.remote("work"))

        await awaitCondition(message: "the sheet never listed the remote templates") {
            await MainActor.run { spawn.templates.map(\.name) == ["work-template"] }
        }
        #expect(await fixture.remote.callCount == 1)
    }

    @Test func afterAHostSwitchBothListsShowOnlyTheNewHostsTemplates() async throws {
        let fixture = try await Fixture()
        let spawn = SpawnAgentModel(templateList: fixture.actions.$templateList.eraseToAnyPublisher())
        fixture.selection.select(.local)
        await awaitCondition { await fixture.names() == ["local-template"] }
        let history = Recorder(fixture.actions.$templateList.eraseToAnyPublisher())

        fixture.selection.select(.remote("work"))

        #expect(fixture.actions.templateList == .loading, "the old host's list must be gone the moment the host switches")
        await awaitCondition { await fixture.names() == ["work-template"] }
        #expect(spawn.templates.map(\.name) == ["work-template"])
        let afterSwitch = history.values.dropFirst()
        #expect(!afterSwitch.contains { $0.templates.map(\.name).contains("local-template") })

        fixture.selection.select(.local)

        await awaitCondition { await fixture.names() == ["local-template"] }
        #expect(spawn.templates.map(\.name) == ["local-template"])
    }

    /// A fetch for the old host that completes after the switch must never
    /// land in the published list.
    @Test func aStaleFetchForTheOldHostNeverLandsAfterASwitch() async throws {
        let fixture = try await Fixture(gateLocal: true)
        fixture.selection.select(.local)
        await fixture.local.waitForCalls(1)

        fixture.selection.select(.remote("work"))
        await awaitCondition { await fixture.names() == ["work-template"] }
        let history = Recorder(fixture.actions.$templateList.eraseToAnyPublisher())
        await fixture.local.resume()
        for _ in 0..<50 { await Task.yield() }

        #expect(fixture.actions.templateList == .loaded([LeoTemplate(name: "work-template")]))
        #expect(history.values == [.loaded([LeoTemplate(name: "work-template")])])
    }

    @Test func aFailedFetchPublishesTheErrorAndTheSpawnModelSurfacesIt() async throws {
        let fixture = try await Fixture(remoteStatus: 255)
        let spawn = SpawnAgentModel(templateList: fixture.actions.$templateList.eraseToAnyPublisher())

        fixture.selection.select(.remote("work"))

        await awaitCondition {
            await MainActor.run { if case .failed = fixture.actions.templateList { true } else { false } }
        }
        #expect(spawn.templates.isEmpty)
        #expect(spawn.templateError?.contains("Permission denied") == true)
    }

    /// A user-initiated sidebar refresh re-reads the same host's templates
    /// into the published list, without blanking it meanwhile.
    @Test func manualRefreshRefetchesThePublishedList() async throws {
        let fixture = try await Fixture()
        fixture.selection.select(.remote("work"))
        await awaitCondition { await fixture.names() == ["work-template"] }
        let history = Recorder(fixture.actions.$templateList.eraseToAnyPublisher())

        fixture.actions.invalidateTemplateCache()

        await awaitCondition { await fixture.remote.callCount == 2 }
        #expect(!history.values.contains(.loading))
    }

    // MARK: Fixture

    @MainActor private final class Fixture {
        let selection: LeoHostSelection
        let actions: LeoAgentActions
        let local: GatedTemplateProcess
        let remote: GatedTemplateProcess

        init(gateLocal: Bool = false, remoteStatus: Int32 = 0) async throws {
            let defaults = LeoInMemoryDefaults()
            defaults.set(try JSONEncoder().encode([LeoTemplateListTests.work]), forKey: LeoHostStore.key)
            selection = LeoHostSelection.isolatedForTesting(defaults: defaults)
            await selection.start(flavor: .socketEvents)
            local = GatedTemplateProcess(name: "local-template", gated: gateLocal)
            remote = GatedTemplateProcess(name: "work-template", gated: false, status: remoteStatus)
            actions = LeoAgentActions(
                daemon: NoTemplateDaemon(),
                cli: LeoCLI(executableOverride: "/leo", runner: local, isExecutable: { _ in true }),
                model: LeoSidebarModel(), hostSelection: selection, processRunner: remote, refresh: {}
            )
        }

        func names() -> [String]? {
            if case .loaded(let templates) = actions.templateList { return templates.map(\.name) }
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
