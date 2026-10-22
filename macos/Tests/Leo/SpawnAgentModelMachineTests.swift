import Combine
import Foundation
import Testing
@testable import Ghostty
@testable import LeoKit

/// S7: the spawn sheet's Machine field. It defaults through
/// `LeoSpawnMachineDefault`, lists unreachable machines without letting
/// them be picked, locks to the source agent's machine for a worktree, and
/// re-reads templates, environments and feature gates from whichever
/// machine is chosen.
@MainActor struct SpawnAgentModelMachineTests {
    private static let work = LeoHostID.remote("work")
    private static let lab = LeoHostID.remote("lab")

    // MARK: Defaults

    @Test func defaultsToTheContextMachine() {
        let harness = Harness()
        #expect(harness.model(context: Self.work).machine == Self.work)
    }

    @Test func fallsBackToTheLastUsedMachineThenThisMac() {
        let harness = Harness()
        #expect(harness.model(lastUsed: Self.lab).machine == Self.lab)
        #expect(harness.model().machine == .local)
    }

    @Test func anUnreachableContextFallsThroughToTheLastUsedMachine() {
        let harness = Harness(statuses: [Self.work: .failed("timed out")])
        #expect(harness.model(context: Self.work, lastUsed: Self.lab).machine == Self.lab)
    }

    // MARK: Picking

    @Test func choosingAMachineSwitchesItAndReloadsItsData() {
        let harness = Harness()
        let model = harness.model()

        model.choose(Self.work)

        #expect(model.machine == Self.work)
        #expect(harness.reloaded == [Self.work])
    }

    @Test func anUnreachableMachineCannotBePicked() {
        let harness = Harness(statuses: [Self.work: .failed("timed out"), Self.lab: .disabled])
        let model = harness.model()

        model.choose(Self.work)
        model.choose(Self.lab)

        #expect(model.machine == .local)
        #expect(harness.reloaded.isEmpty)
    }

    @Test func aMachineThatIsNotListedCannotBePicked() {
        let harness = Harness()
        let model = harness.model()

        model.choose(.remote("gone"))

        #expect(model.machine == .local)
    }

    @Test func aChosenMachineThatGoesUnreachableBlocksCreate() {
        let harness = Harness()
        harness.setTemplates(["claude"], for: Self.work)
        let model = harness.model(context: Self.work)
        model.template = "claude"
        #expect(model.validationError == nil)

        harness.setStatus(.failed("timed out"), for: Self.work)

        #expect(model.validationError == "work is unavailable")
    }

    // MARK: Switching reloads

    @Test func templatesFollowTheChosenMachine() {
        let harness = Harness()
        harness.setTemplates(["local-t"], for: .local)
        harness.setTemplates(["work-t"], for: Self.work)
        let model = harness.model()
        #expect(model.templates.map(\.name) == ["local-t"])

        model.choose(Self.work)

        #expect(model.templates.map(\.name) == ["work-t"])
        harness.setTemplates(["work-t", "more"], for: Self.work)
        #expect(model.templates.map(\.name) == ["work-t", "more"])
    }

    @Test func aLateListForTheMachineLeftBehindIsIgnored() {
        let harness = Harness()
        harness.setTemplates(["local-t"], for: .local)
        let model = harness.model()
        model.choose(Self.work)

        harness.setTemplates(["local-late"], for: .local)

        #expect(model.templates.isEmpty)
    }

    /// The new machine may not have it, but that is what validation says.
    @Test func switchingKeepsTheTemplateAndValidationFlagsOneTheNewMachineLacks() {
        let harness = Harness()
        harness.setTemplates(["claude"], for: .local)
        harness.setTemplates(["other"], for: Self.work)
        let model = harness.model()
        model.template = "claude"

        model.choose(Self.work)

        #expect(model.template == "claude")
        #expect(model.validationError == "Choose an available template")
    }

    @Test func switchingResetsEditedEnvironmentsToTheNewMachinesDefault() {
        let harness = Harness()
        harness.setTemplates(["claude"], for: .local)
        harness.setTemplates(["claude"], for: Self.work)
        harness.setCatalog(LeoEnvironmentCatalog(names: ["aws", "dev"], templateDefaults: ["claude": ["aws"]]), for: .local)
        harness.setCatalog(LeoEnvironmentCatalog(names: ["prod", "dev"], templateDefaults: ["claude": ["prod"]]), for: Self.work)
        harness.setSupportsEnvironments(true, for: .local)
        harness.setSupportsEnvironments(true, for: Self.work)
        let model = harness.model()
        model.template = "claude"
        model.editEnvironments(LeoEnvironmentList(["dev"]))

        model.choose(Self.work)
        model.template = "claude"

        #expect(model.environments.names == ["prod"])
        #expect(model.request().environments == nil)
    }

    @Test func theEnvironmentsGateFollowsTheChosenMachine() {
        let harness = Harness()
        harness.setSupportsEnvironments(true, for: .local)
        harness.setSupportsEnvironments(false, for: Self.work)
        let model = harness.model()
        #expect(model.showsEnvironments)

        model.choose(Self.work)

        #expect(!model.showsEnvironments)
    }

    // MARK: Worktree lock

    @Test func aWorktreeSpawnIsLockedToTheSourcesMachine() {
        let harness = Harness()
        let model = harness.model(source: Self.sourceRow(on: Self.work), context: .local)

        #expect(model.isMachineLocked)
        #expect(model.machine == Self.work)
        model.choose(.local)
        #expect(model.machine == Self.work)
        #expect(harness.reloaded.isEmpty)
    }

    @Test func theUnavailableMessageNamesThisMacNotLocalhost() {
        let harness = Harness(statuses: [.local: .failed("daemon stopped")])
        #expect(harness.model().validationError == "This Mac is unavailable")
    }

    @Test func onlyThisMacCanBrowseForARepositoryFolder() {
        let harness = Harness()
        let model = harness.model()
        #expect(model.canBrowseRepository)

        model.choose(Self.work)

        #expect(!model.canBrowseRepository)
    }

    @Test func aWorktreeOnAnUnreachableMachineIsBlocked() {
        let harness = Harness(statuses: [Self.work: .failed("timed out")])
        let model = harness.model(source: Self.sourceRow(on: Self.work))
        model.branch = "feat/x"

        #expect(model.validationError == "work is unavailable")
    }

    @Test func aPlainSpawnIsNotLocked() {
        #expect(!Harness().model().isMachineLocked)
    }

    // MARK: Spawn

    @Test func spawnRunsOnTheChosenMachineAndRemembersItOnSuccess() async {
        let harness = Harness()
        let daemons = [LeoHostID.local: WorktreeDaemon(), Self.work: WorktreeDaemon()]
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemons: daemons), cli: .recordingForTests(templates: ["claude"]), model: LeoSidebarModel(),
            processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        let model = harness.model()
        model.choose(Self.work)
        model.template = "claude"
        var dismissed = false

        model.spawn(model.request(), actions: actions, attach: { _, _ in }, dismiss: { dismissed = true })

        await awaitCondition { await MainActor.run { dismissed } }
        #expect(await daemons[Self.work]?.requests.count == 1)
        #expect(await daemons[.local]?.requests.isEmpty == true)
        #expect(harness.remembered == [Self.work])
    }

    @Test func aFailedSpawnRemembersNothing() async {
        let harness = Harness()
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemons: [:]), cli: .recordingForTests(templates: ["claude"]), model: LeoSidebarModel(),
            processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        let model = harness.model()
        model.template = "claude"

        model.spawn(model.request(), actions: actions, attach: { _, _ in }, dismiss: {})

        await awaitCondition { await MainActor.run { model.error != nil } }
        #expect(harness.remembered.isEmpty)
    }

    // MARK: Fixtures

    private static func sourceRow(on host: LeoHostID) -> LeoAgentRow {
        LeoAgentRow(host: host, name: "source", template: "claude", status: .running, activity: .idle, actionDetail: nil, repo: "o/r")
    }

    /// Per-machine feeds the test drives by hand.
    @MainActor private final class Harness {
        private let machines: CurrentValueSubject<[SpawnMachineOption], Never>
        private var templates: [LeoHostID: CurrentValueSubject<LeoTemplateListState, Never>] = [:]
        private var catalogs: [LeoHostID: CurrentValueSubject<LeoEnvironmentCatalogState, Never>] = [:]
        private var gates: [LeoHostID: CurrentValueSubject<Bool, Never>] = [:]
        private(set) var reloaded: [LeoHostID] = []
        private(set) var remembered: [LeoHostID] = []

        init(statuses: [LeoHostID: LeoMachineStatus] = [:]) {
            let hosts: [LeoHostID] = [.local, SpawnAgentModelMachineTests.work, SpawnAgentModelMachineTests.lab]
            machines = CurrentValueSubject(hosts.map { SpawnMachineOption(host: $0, status: statuses[$0] ?? .connected) })
        }

        func setStatus(_ status: LeoMachineStatus, for host: LeoHostID) {
            machines.send(machines.value.map { $0.host == host ? SpawnMachineOption(host: host, status: status) : $0 })
        }

        func setTemplates(_ names: [String], for host: LeoHostID) {
            templateSubject(host).send(.loaded(names.map { LeoTemplate(name: $0) }))
        }

        func setCatalog(_ catalog: LeoEnvironmentCatalog, for host: LeoHostID) { catalogSubject(host).send(.loaded(catalog)) }
        func setSupportsEnvironments(_ value: Bool, for host: LeoHostID) { gateSubject(host).send(value) }

        func model(source: LeoAgentRow? = nil, context: LeoHostID? = nil, lastUsed: LeoHostID? = nil) -> SpawnAgentModel {
            SpawnAgentModel(
                source: source, context: context, lastUsed: lastUsed,
                feeds: SpawnMachineFeeds(
                    machines: machines.eraseToAnyPublisher(),
                    templateList: { [unowned self] in templateSubject($0).eraseToAnyPublisher() },
                    environmentCatalog: { [unowned self] in catalogSubject($0).eraseToAnyPublisher() },
                    environmentsSupported: { [unowned self] in gateSubject($0).eraseToAnyPublisher() },
                    reload: { [unowned self] in reloaded.append($0) }
                ),
                remember: { [unowned self] in remembered.append($0) }
            )
        }

        private func templateSubject(_ host: LeoHostID) -> CurrentValueSubject<LeoTemplateListState, Never> {
            if let subject = templates[host] { return subject }
            let subject = CurrentValueSubject<LeoTemplateListState, Never>(.loading)
            templates[host] = subject
            return subject
        }

        private func catalogSubject(_ host: LeoHostID) -> CurrentValueSubject<LeoEnvironmentCatalogState, Never> {
            if let subject = catalogs[host] { return subject }
            let subject = CurrentValueSubject<LeoEnvironmentCatalogState, Never>(.loading)
            catalogs[host] = subject
            return subject
        }

        private func gateSubject(_ host: LeoHostID) -> CurrentValueSubject<Bool, Never> {
            if let subject = gates[host] { return subject }
            let subject = CurrentValueSubject<Bool, Never>(false)
            gates[host] = subject
            return subject
        }
    }
}
