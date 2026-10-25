import Combine
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoSettingsTargetModelTests {
    private static let dionysus = LeoHostID.remote("dionysus")
    private static let hestia = LeoHostID.remote("hestia")

    private final class Pane: LeoSettingsPane {
        var hasUnsavedChanges: Bool
        private(set) var discards = 0
        private(set) var reloaded: [any LeoConfigClient] = []
        init(dirty: Bool) { hasUnsavedChanges = dirty }
        func discardChanges() { hasUnsavedChanges = false; discards += 1 }
        func reload(using client: any LeoConfigClient) async { reloaded.append(client) }
    }

    private struct Harness {
        let model: LeoSettingsTargetModel
        let clients: FakeMachineClients
        let statuses: PassthroughSubject<[LeoHostID: LeoMachineStatus], Never>
        let reconnects: Reconnects
        /// Drives the Service model's polling by hand.
        let ticker: ServiceTicker

        /// A status change as the registry makes it: the lookup and the publisher agree.
        @MainActor func publish(_ host: LeoHostID, _ status: LeoMachineStatus) {
            reconnects.statuses[host] = status
            statuses.send([host: status])
        }
    }

    @MainActor private final class Reconnects {
        var hosts: [LeoHostID] = []
        /// What `status` answers; `Harness.publish` keeps it in step with the publisher.
        var statuses: [LeoHostID: LeoMachineStatus] = [:]
    }

    private static func config(supported: Bool = true, version: String = "0.52.0") -> LeoFakeConfigClient {
        LeoFakeConfigClient(
            schema: LeoConfigSchema(resources: []),
            version: LeoDaemonVersionInfo(version: version, capabilities: supported ? [LeoConfigAPI.capability] : [])
        )
    }

    @MainActor private static func harness(
        daemons: [LeoHostID: LeoFakeConfigClient] = [:], statuses initial: [LeoHostID: LeoMachineStatus] = [:],
        initialHost: LeoHostID? = nil, machines: @escaping () -> [LeoHostID] = { [.local, dionysus, hestia] }
    ) -> Harness {
        let clients = FakeMachineClients(daemons: daemons.mapValues { ConfigStubDaemon(config: $0) })
        let subject = PassthroughSubject<[LeoHostID: LeoMachineStatus], Never>()
        let reconnects = Reconnects()
        reconnects.statuses = initial
        let ticker = ServiceTicker()
        let model = LeoSettingsTargetModel(
            clients: clients, machines: machines, status: { reconnects.statuses[$0] }, statuses: subject.eraseToAnyPublisher(),
            reconnect: { reconnects.hosts.append($0) }, initialHost: initialHost,
            makeService: { client, machine in
                LeoServiceSettingsModel(client: client, machine: machine, sleep: { try await ticker.sleep($0) }, copyToPasteboard: { _ in })
            }
        )
        return Harness(model: model, clients: clients, statuses: subject, reconnects: reconnects, ticker: ticker)
    }

    // MARK: target

    @Test func defaultsToTheSelectedAgentsMachine() {
        #expect(Self.harness(initialHost: Self.dionysus).model.selectedHost == Self.dionysus)
    }

    @Test func defaultsToThisMacWithNoSelectedAgent() {
        #expect(Self.harness().model.selectedHost == .local)
    }

    @Test func aMachineThatIsNoLongerConfiguredFallsBackToThisMac() {
        let harness = Self.harness(initialHost: Self.hestia, machines: { [.local, Self.dionysus] })
        #expect(harness.model.selectedHost == .local)
    }

    // MARK: availability

    @Test func aConnectedMachineWithTheConfigAPIIsReady() async {
        let harness = Self.harness(daemons: [.local: Self.config()])
        #expect(harness.model.isLoading)
        await harness.model.settled()

        guard case .ready = harness.model.availability else {
            Issue.record("Expected ready, got \(harness.model.availability)")
            return
        }
    }

    @Test func anOldDaemonIsTooOldNotAHalfForm() async {
        let harness = Self.harness(daemons: [.local: Self.config(supported: false, version: "0.40.0")])
        await harness.model.settled()

        guard case .tooOld(let info) = harness.model.availability else {
            Issue.record("Expected tooOld, got \(harness.model.availability)")
            return
        }
        #expect(info?.version == "0.40.0")
    }

    @Test func aDisconnectedMachineShowsItsStatusAndReconnectAsksTheRegistry() async {
        let harness = Self.harness(statuses: [.local: .failed("connection refused")])
        await harness.model.settled()

        guard case .disconnected(let status) = harness.model.availability else {
            Issue.record("Expected disconnected")
            return
        }
        #expect(status == .failed("connection refused"))
        harness.model.reconnect()
        #expect(harness.reconnects.hosts == [.local])
    }

    @Test func aStatusChangeOnTheSelectedMachineLooksAgain() async {
        let harness = Self.harness(statuses: [.local: .failed("down")])
        await harness.model.settled()
        harness.clients.connect(.local, ConfigStubDaemon(config: Self.config()))
        harness.statuses.send([.local: .connected])
        await harness.model.settled()

        guard case .ready = harness.model.availability else {
            Issue.record("Expected ready, got \(harness.model.availability)")
            return
        }
    }

    @Test func aStatusChangeOnAnotherMachineIsIgnored() async {
        let harness = Self.harness(daemons: [.local: Self.config()])
        await harness.model.settled()
        let before = harness.model.generation
        harness.statuses.send([Self.dionysus: .failed("x")])

        #expect(harness.model.generation == before)
    }

    @Test func aClientBoundAfterTheConnectionCameUpIsPickedUp() async {
        let harness = Self.harness(statuses: [.local: .connected])
        await harness.model.settled()
        guard case .loading = harness.model.availability else {
            Issue.record("A connected machine still building its client is loading")
            return
        }

        harness.clients.connect(.local, ConfigStubDaemon(config: Self.config()))
        harness.clients.announceClientChange(.local)
        await harness.model.settled()

        guard case .ready = harness.model.availability else {
            Issue.record("Expected ready, got \(harness.model.availability)")
            return
        }
    }

    // MARK: switching

    @Test func switchingMachinesReloadsAndForgetsTheOldRevisions() async {
        let harness = Self.harness(daemons: [.local: Self.config(), Self.dionysus: Self.config()])
        await harness.model.settled()
        let before = harness.model.generation
        harness.model.revisions.recordWrite(from: "a", to: "b")

        #expect(harness.model.requestSwitch(to: Self.dionysus))
        await harness.model.settled()

        #expect(harness.model.selectedHost == Self.dionysus)
        #expect(harness.model.generation > before)
        #expect(harness.model.revisions.resolve("a") == "a")
        guard case .ready = harness.model.availability else {
            Issue.record("Expected ready")
            return
        }
    }

    @Test func aLateReplyFromTheOldMachineIsDropped() async {
        let slow = Self.config()
        let fast = Self.config()
        await slow.holdReads()
        let harness = Self.harness(daemons: [.local: slow, Self.dionysus: fast])
        await awaitCondition { await slow.heldReadCount == 1 }

        #expect(harness.model.requestSwitch(to: Self.dionysus))
        await harness.model.settled()
        await slow.releaseReads()
        for _ in 0..<20 { await Task.yield() }
        await harness.model.settled()

        guard case .ready(let client) = harness.model.availability else {
            Issue.record("Expected ready")
            return
        }
        #expect((client as? LeoFakeConfigClient) === fast)
    }

    @Test func switchingToTheSelectedMachineChangesNothing() async {
        let harness = Self.harness(daemons: [.local: Self.config()])
        await harness.model.settled()
        let before = harness.model.generation

        #expect(harness.model.requestSwitch(to: .local))
        #expect(harness.model.generation == before)
    }

    // MARK: a same-machine reconnect

    /// A tunnel blip: the machine's client goes away and a new one is bound.
    private static func blip(_ harness: Harness, host: LeoHostID = .local, to config: LeoFakeConfigClient) async {
        harness.clients.disconnect(host)
        harness.publish(host, .failed("tunnel dropped"))
        await harness.model.settled()
        harness.clients.connect(host, ConfigStubDaemon(config: config))
        harness.publish(host, .connected)
        await harness.model.settled()
    }

    @Test func aDirtyPaneStaysMountedAcrossAReconnectAndKeepsItsEdits() async {
        let harness = Self.harness(daemons: [.local: Self.config()], statuses: [.local: .connected])
        let tab = LeoSettingsTab.config("templates")
        let pane = Pane(dirty: true)
        harness.model.register(pane, for: tab)
        await harness.model.settled()
        let epoch = harness.model.machineEpoch
        #expect(harness.model.retainedClient(for: tab) != nil)

        harness.clients.disconnect(.local)
        harness.publish(.local, .failed("tunnel dropped"))
        await harness.model.settled()

        guard case .disconnected = harness.model.availability else {
            Issue.record("Expected disconnected")
            return
        }
        #expect(harness.model.machineEpoch == epoch)
        #expect(harness.model.retainedClient(for: tab) != nil)
        #expect(pane.discards == 0)
        #expect(pane.hasUnsavedChanges)
    }

    @Test func aReconnectReloadsTheMountedPaneWithTheNewClient() async {
        let harness = Self.harness(daemons: [.local: Self.config()], statuses: [.local: .connected])
        let pane = Pane(dirty: true)
        harness.model.register(pane, for: .config("templates"))
        await harness.model.settled()
        let epoch = harness.model.machineEpoch
        let replacement = Self.config()
        await Self.blip(harness, to: replacement)

        #expect(pane.reloaded.count == 1)
        #expect((pane.reloaded.first as? LeoFakeConfigClient) === replacement)
        #expect(pane.discards == 0)
        #expect(pane.hasUnsavedChanges)
        #expect(harness.model.machineEpoch == epoch)
    }

    @Test func aCleanPaneIsNotRetainedWhileTheMachineIsGone() async {
        let harness = Self.harness(daemons: [.local: Self.config()], statuses: [.local: .connected])
        let tab = LeoSettingsTab.config("templates")
        let pane = Pane(dirty: false)
        harness.model.register(pane, for: tab)
        await harness.model.settled()

        harness.clients.disconnect(.local)
        harness.publish(.local, .failed("down"))
        await harness.model.settled()

        #expect(harness.model.retainedClient(for: tab) == nil)
        withExtendedLifetime(pane) {}
    }

    @Test func onlyTheDirtyTabsPaneIsRetained() async {
        let harness = Self.harness(daemons: [.local: Self.config()], statuses: [.local: .connected])
        let dirty = Pane(dirty: true)
        let clean = Pane(dirty: false)
        harness.model.register(dirty, for: .config("templates"))
        harness.model.register(clean, for: .config("tasks"))
        await harness.model.settled()

        harness.clients.disconnect(.local)
        harness.publish(.local, .failed("down"))
        await harness.model.settled()

        #expect(harness.model.retainedClient(for: .config("templates")) != nil)
        #expect(harness.model.retainedClient(for: .config("tasks")) == nil)
        withExtendedLifetime((dirty, clean)) {}
    }

    // MARK: restarting the daemon

    @Test func theRestartActionsRestartTheDaemonThroughTheCurrentClient() async {
        let fake = Self.config()
        let harness = Self.harness(daemons: [.local: fake], statuses: [.local: .connected])
        await harness.model.settled()

        #expect(await harness.model.restartActions.restartService?() == nil)
        #expect(await fake.calls.contains(.restartService))
    }

    @Test func theAgentsRestartActionRestartsThemThroughTheCurrentClient() async {
        let fake = Self.config()
        let harness = Self.harness(daemons: [.local: fake], statuses: [.local: .connected])
        await harness.model.settled()

        #expect(await harness.model.restartActions.restartAgents?() == nil)
        #expect(await fake.calls.contains(.restartAgents))
    }

    @Test func theAgentsRestartPromptLearnsHowManyAgentsAreRunning() async {
        let fake = Self.config()
        await fake.setService(LeoFakeServiceState(processes: [
            LeoServiceProcess(name: "coder", status: "running"), LeoServiceProcess(name: "reviewer", status: "running"),
            LeoServiceProcess(name: "old", status: "stopped"),
        ]))
        let harness = Self.harness(daemons: [.local: fake], statuses: [.local: .connected])
        await harness.model.settled()

        #expect(await harness.model.restartActions.runningAgents?() == 2)
    }

    @Test func withNoConnectionTheAgentCountIsUnknown() async {
        let harness = Self.harness(statuses: [.local: .failed("down")])
        await harness.model.settled()

        #expect(await harness.model.restartActions.runningAgents?() == nil)
    }

    @Test func aRestartThatFailsComesBackAsTextForThePromptToShow() async {
        let fake = Self.config()
        let harness = Self.harness(daemons: [.local: fake], statuses: [.local: .connected])
        await harness.model.settled()
        await fake.failNextWrite(with: LeoDaemonError.transport("tunnel dropped"))

        #expect(await harness.model.restartActions.restartService?() != nil)
        await fake.failNextWrite(with: LeoDaemonError.transport("tunnel dropped"))
        #expect(await harness.model.restartActions.restartAgents?() != nil)
    }

    @Test func aRestartWithNoConnectionSaysSoInsteadOfDoingNothing() async {
        let harness = Self.harness(statuses: [.local: .failed("down")])
        await harness.model.settled()

        #expect(await harness.model.restartActions.restartService?()?.contains("Not connected") == true)
        #expect(await harness.model.restartActions.restartAgents?()?.contains("Not connected") == true)
    }

    /// The daemon restarting drops this app's connection to it. The reconnect
    /// is the usual one: a dirty pane keeps its edits and reloads, and the
    /// Service pane, which is waiting for the daemon, stays on screen.
    @Test func aDaemonRestartIsRiddenOutWithoutLosingAnyPanesDrafts() async {
        let old = Self.config()
        let harness = Self.harness(daemons: [.local: old], statuses: [.local: .connected])
        let dirty = Pane(dirty: true)
        let templates = LeoSettingsTab.config("templates")
        harness.model.register(dirty, for: templates)
        await harness.model.settled()
        let epoch = harness.model.machineEpoch
        #expect(await harness.model.restartActions.restartService?() == nil)
        let service = harness.model.service(using: old)
        #expect(service.isRestarting)

        harness.clients.disconnect(.local)
        harness.publish(.local, .failed("tunnel dropped"))
        await harness.model.settled()

        #expect(harness.model.retainedClient(for: .service) != nil)
        #expect(harness.model.retainedClient(for: templates) != nil)
        #expect(harness.model.machineEpoch == epoch)

        let replacement = Self.config()
        await replacement.setService(LeoFakeServiceState(pid: 2, startedAt: Date(timeIntervalSince1970: 1_792_738_860)))
        harness.clients.connect(.local, ConfigStubDaemon(config: replacement))
        harness.publish(.local, .connected)
        await harness.model.settled()
        await harness.ticker.tick()
        await service.settledRestart()

        #expect(!service.isRestarting)
        #expect(service.notice?.hasPrefix("leo restarted on") == true)
        #expect(service.status?.pid == 2)
        #expect((dirty.reloaded.last as? LeoFakeConfigClient) === replacement)
        #expect(dirty.discards == 0)
        #expect(dirty.hasUnsavedChanges)
        #expect(harness.model.machineEpoch == epoch)
    }

    @Test func theServicePaneGivesWayOnceNothingIsWaitingOnTheDaemon() async {
        let old = Self.config()
        let harness = Self.harness(daemons: [.local: old], statuses: [.local: .connected])
        await harness.model.settled()
        _ = harness.model.service(using: old)

        harness.clients.disconnect(.local)
        harness.publish(.local, .failed("down"))
        await harness.model.settled()

        #expect(harness.model.retainedClient(for: .service) == nil)
    }

    @Test func aMachineSwitchStopsTheOldMachinesServiceModelAndStartsAFreshOne() async {
        let old = Self.config()
        let harness = Self.harness(daemons: [.local: old, Self.dionysus: Self.config()], statuses: [.local: .connected])
        await harness.model.settled()
        let service = harness.model.service(using: old)
        #expect(await harness.model.restartActions.restartService?() == nil)
        #expect(service.isRestarting)

        harness.model.requestSwitch(to: Self.dionysus)
        await harness.model.settled()

        #expect(!service.isRestarting)
        guard case .ready(let client) = harness.model.availability else {
            Issue.record("Expected ready")
            return
        }
        #expect(harness.model.service(using: client) !== service)
    }

    @Test func aMachineSwitchIsANewIdentityButARefreshIsNot() async {
        let harness = Self.harness(daemons: [.local: Self.config(), Self.dionysus: Self.config()], statuses: [.local: .connected])
        await harness.model.settled()
        let epoch = harness.model.machineEpoch
        harness.model.refresh()
        await harness.model.settled()
        #expect(harness.model.machineEpoch == epoch)

        _ = harness.model.requestSwitch(to: Self.dionysus)
        #expect(harness.model.machineEpoch > epoch)
    }

    @Test func aMachineSwitchDoesNotReloadTheOldMachinesPane() async {
        let harness = Self.harness(daemons: [.local: Self.config(), Self.dionysus: Self.config()], statuses: [.local: .connected])
        let pane = Pane(dirty: false)
        harness.model.register(pane, for: .config("templates"))
        await harness.model.settled()

        _ = harness.model.requestSwitch(to: Self.dionysus)
        await harness.model.settled()

        #expect(pane.reloaded.isEmpty)
    }

    // MARK: unsaved changes

    @Test func aDirtyPaneMakesAMachineSwitchAskFirst() async {
        let harness = Self.harness(daemons: [.local: Self.config(), Self.dionysus: Self.config()])
        let pane = Pane(dirty: true)
        harness.model.register(pane, for: .config("templates"))

        #expect(!harness.model.requestSwitch(to: Self.dionysus))
        #expect(harness.model.selectedHost == .local)
        #expect(harness.model.pendingChange == .machine(Self.dionysus))
        #expect(pane.discards == 0)

        harness.model.confirmPendingChange()
        #expect(harness.model.selectedHost == Self.dionysus)
        #expect(harness.model.pendingChange == nil)
        #expect(pane.discards == 1)
    }

    @Test func cancellingTheAskKeepsTheMachineAndTheEdits() {
        let harness = Self.harness(daemons: [.local: Self.config()])
        let pane = Pane(dirty: true)
        harness.model.register(pane, for: .config("templates"))
        _ = harness.model.requestSwitch(to: Self.dionysus)
        harness.model.cancelPendingChange()

        #expect(harness.model.selectedHost == .local)
        #expect(harness.model.pendingChange == nil)
        #expect(pane.hasUnsavedChanges)
    }

    @Test func aCleanPaneSwitchesWithoutAsking() {
        let harness = Self.harness()
        harness.model.register(Pane(dirty: false), for: .config("templates"))

        #expect(harness.model.requestSwitch(to: Self.dionysus))
        #expect(harness.model.pendingChange == nil)
    }

    @Test func leavingADirtyTabAsksFirst() {
        let harness = Self.harness()
        let templates = Pane(dirty: true)
        harness.model.register(templates, for: .config("templates"))
        #expect(harness.model.requestTab(.config("templates")))

        #expect(!harness.model.requestTab(.config("tasks")))
        #expect(harness.model.selectedTab == .config("templates"))
        #expect(harness.model.pendingChange == .tab(.config("tasks")))

        harness.model.confirmPendingChange()
        #expect(harness.model.selectedTab == .config("tasks"))
        #expect(templates.discards == 1)
    }

    @Test func leavingACleanTabJustSwitches() {
        let harness = Self.harness()
        harness.model.register(Pane(dirty: false), for: .config("templates"))
        _ = harness.model.requestTab(.config("templates"))

        #expect(harness.model.requestTab(.machines))
        #expect(harness.model.selectedTab == .machines)
    }

    @Test func aPaneThatWasReleasedCountsAsClean() {
        let harness = Self.harness()
        var pane: Pane? = Pane(dirty: true)
        harness.model.register(pane!, for: .config("templates"))
        pane = nil

        #expect(!harness.model.hasUnsavedChanges)
    }

    @Test func onlyConfigTabsUseTheMachinePicker() {
        #expect(!LeoSettingsTab.machines.usesMachineTarget)
        #expect(LeoSettingsTab.config("templates").usesMachineTarget)
    }
}
