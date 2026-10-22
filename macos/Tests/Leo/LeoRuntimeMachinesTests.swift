import Combine
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// `LeoRuntime` runs every machine on its own: each has its own connection,
/// feed and client, so one machine's trouble never reaches another's rows.
/// Remote machines run fake tunnels and fake daemons.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor struct LeoRuntimeMachinesTests {
    private typealias Support = LeoMachineRegistryTestSupport
    nonisolated private static let quiet = LeoSidebarActivitySource(events: { AsyncStream { _ in } }, fetchState: { [] })

    @Test func everyMachineIsFedByDefault() {
        #expect(LeoRuntime.feedsRemoteMachinesByDefault)
    }

    @Test func remoteMachinesCanBeKeptOffTheSidebar() throws {
        let runtime = try makeRuntime(machines: ["a"], feedsRemoteMachines: false)

        #expect(runtime.model.machineOrder == [.local])
        #expect(runtime.feeds.hosts == [.local])
    }

    /// A disabled machine is never connected, so it has no section to sit
    /// in "Loading" forever; enabling it brings the section back.
    @Test func aDisabledMachineHasNoSectionUntilItIsEnabled() throws {
        let runtime = try makeRuntime(machines: ["a", "off"], disabled: ["off"])
        defer { runtime.shutdown() }

        #expect(runtime.model.machineOrder == [.local, .remote("a")])
        #expect(runtime.feeds.hosts == [.local, .remote("a")])

        #expect(try runtime.machines.setEnabled(.remote("off"), true))
        #expect(runtime.model.machineOrder == [.local, .remote("a"), .remote("off")])

        #expect(try runtime.machines.setEnabled(.remote("a"), false))
        #expect(runtime.model.machineOrder == [.local, .remote("off")])
    }

    /// The model learns every machine before any of their feeds can deliver.
    @Test func everyShownMachineIsKnownToTheModelBeforeItsFeedStarts() throws {
        let runtime = try makeRuntime(machines: ["a", "b"])

        #expect(runtime.model.machineOrder == [.local, .remote("a"), .remote("b")])
        #expect(runtime.feeds.hosts == runtime.model.machineOrder)
    }

    /// The spawn sheet lists machines from the model, so the runtime mirrors
    /// the registry's statuses onto it as they change.
    @Test func theModelMirrorsEveryMachinesStatusForTheSpawnPicker() async throws {
        let runtime = try makeRuntime(machines: ["a", "b"])
        defer { runtime.shutdown() }
        #expect(runtime.model.machineStatuses[.remote("a")] == .connecting)

        start(runtime)

        try await until { @MainActor in
            runtime.model.machineStatuses[.remote("a")] == .connected && runtime.model.machineStatuses[.local] == .connected
        }
    }

    /// The poller is wired to the live model: a machine advertising
    /// `machine_stats` gets its sample into the sidebar header's section and
    /// the spawn picker's option, and one that doesn't gets none.
    @Test func theStatsPollerFeedsTheHeadersAndThePicker() async throws {
        let runtime = try makeRuntime(machines: ["a", "old"]) { host, _ in
            let advertises = host == .remote("a")
            return LeoMachineDaemon(
                daemon: LeoStatsListingDaemon(cpu: 33),
                activitySource: LeoSidebarActivitySource(
                    events: {
                        AsyncStream { $0.yield(.hello(
                            seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot",
                            features: advertises ? ["machine_stats"] : []
                        )) }
                    },
                    fetchState: { [] }
                )
            )
        }
        defer { runtime.shutdown() }
        runtime.statsPoller.setSidebarPollable(true)
        runtime.statsPoller.setAppActive(true)
        start(runtime)

        try await until { @MainActor in runtime.model.machineStats[.remote("a")]?.cpu?.percent == 33 }
        #expect(runtime.model.machineSections.first { $0.host == .remote("a") }?.stats?.cpu?.percent == 33)
        var options: [SpawnMachineOption] = []
        let subscription = SpawnMachineFeeds.live(sidebar: runtime.model, actions: runtime.actions).machines.sink { options = $0 }
        defer { subscription.cancel() }
        #expect(options.first { $0.host == .remote("a") }?.stats?.cpu?.percent == 33)
        #expect(runtime.model.machineStats[.remote("old")] == nil)
    }

    @Test func aMachineWhoseTunnelDiesLeavesEveryOtherMachinesRowsConnected() async throws {
        let tunnels = LeoFakeTunnels()
        let runtime = try makeRuntime(machines: ["a", "b"], tunnels: tunnels)
        defer { runtime.shutdown() }
        start(runtime)
        try await until { @MainActor in rows(runtime, "a") == ["a-agent"] && rows(runtime, "b") == ["b-agent"] }

        tunnels.tunnels("evan@b").first?.exit()

        try await until { @MainActor in runtime.model.isDisconnected(.remote("b")) }
        #expect(runtime.model.snapshot(for: .remote("a"))?.connectivity == .connected)
        #expect(rows(runtime, "a") == ["a-agent"])
        #expect(runtime.model.snapshot(for: .local)?.connectivity == .connected)
    }

    /// ⇧⌘R and the banner's Retry reconnect every machine that would offer
    /// Retry, and leave the connected ones alone.
    @Test func reconnectingAllRetriesOnlyTheMachinesThatAreDown() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .fails("Connection refused"), .hangs)
        let runtime = try makeRuntime(machines: ["a", "b"], tunnels: tunnels)
        defer { runtime.shutdown() }
        start(runtime)
        try await until { @MainActor in rows(runtime, "a") == ["a-agent"] && isDown(runtime, "b") }
        let generations = [LeoHostID.local, .remote("a")].map(runtime.machines.generation(for:))

        runtime.model.retryRequested()

        try await until { tunnels.tunnels("evan@b").count == 2 }
        #expect([LeoHostID.local, .remote("a")].map(runtime.machines.generation(for:)) == generations)
        #expect(tunnels.tunnels("evan@a").count == 1)
    }

    /// The machine's connection fails while its client is still being built
    /// (a remote flavor probe): the late client is never bound or asked for
    /// anything, and the machine stays failed.
    @Test func aConnectionThatFailsWhileItsClientIsBuiltStaysFailed() async throws {
        let gate = LeoClientBuildGate()
        let late = RuntimeTestDaemon()
        let tunnels = LeoFakeTunnels()
        let templates = LeoRecordingTemplateRunner()
        let runtime = try makeRuntime(machines: ["b"], tunnels: tunnels, templates: templates) { _, _ in
            await gate.pass()
            return LeoMachineDaemon(daemon: late, activitySource: Self.quiet)
        }
        defer { runtime.shutdown() }
        start(runtime)
        try await until { await gate.waiting == 1 }

        tunnels.tunnels("evan@b").first?.exit()
        try await until { @MainActor in isDown(runtime, "b") }
        await gate.open()
        for _ in 0..<50 { await Task.yield() }

        #expect(isDown(runtime, "b"))
        #expect(runtime.clients.daemon(for: .remote("b")) == nil)
        #expect(await late.listCallCount == 0)
        #expect(await templates.calls.isEmpty, "the dead connection's templates were fetched")
    }

    /// A machine removed in Settings and added back gets a fresh feed, whose
    /// first snapshots the model takes although their numbers restart.
    @Test func aMachineRemovedAndAddedBackShowsItsNewConnectionsRows() async throws {
        let defaults = LeoInMemoryDefaults()
        let builds = LeoLockedLog<LeoHostID>()
        let runtime = try makeRuntime(machines: ["a"], defaults: defaults) { host, _ in
            builds.append(host)
            return LeoMachineDaemon(daemon: LeoListingDaemon(names: ["a-\(builds.values.count)"]), activitySource: Self.quiet)
        }
        defer { runtime.shutdown() }
        start(runtime)
        try await until { @MainActor in rows(runtime, "a") == ["a-1"] }

        try Support.save([], to: defaults)
        runtime.machines.reload()
        try Support.save([Support.host("a")], to: defaults)
        runtime.machines.reload()

        try await until { @MainActor in rows(runtime, "a") == ["a-2"] }
    }

    /// A client build that was still running when its machine was removed
    /// finishes after the machine is added back and connected again: the
    /// stale build must not replace the new connection's client.
    @Test func aClientBuiltForARemovedMachineNeverReplacesTheNewConnectionsClient() async throws {
        let defaults = LeoInMemoryDefaults()
        let gate = LeoClientBuildGate()
        let builds = LeoLockedLog<LeoHostID>()
        let runtime = try makeRuntime(machines: ["a"], defaults: defaults) { host, _ in
            builds.append(host)
            if builds.values.count == 1 { await gate.pass() }
            return LeoMachineDaemon(daemon: LeoListingDaemon(names: ["build-\(builds.values.count)"]), activitySource: Self.quiet)
        }
        defer { runtime.shutdown() }
        start(runtime)
        try await until { await gate.waiting == 1 }

        try Support.save([], to: defaults)
        runtime.machines.reload()
        try Support.save([Support.host("a")], to: defaults)
        runtime.machines.reload()
        try await until { @MainActor in runtime.clients.daemon(for: .remote("a")) != nil }
        await gate.open()
        for _ in 0..<100 { await Task.yield() }

        #expect(runtime.clients.daemon(for: .remote("a")) != nil, "the stale build's client replaced the live one")
    }

    /// ⇧⌘R and Retry also restart a machine whose connection is still being
    /// made (its sidebar shows Loading, which offers no Retry of its own).
    @Test func reconnectingAllAlsoRestartsAMachineThatIsStillConnecting() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .hangs)
        let runtime = try makeRuntime(machines: ["a", "b"], tunnels: tunnels)
        defer { runtime.shutdown() }
        start(runtime)
        try await until { @MainActor in rows(runtime, "a") == ["a-agent"] && tunnels.tunnels("evan@b").count == 1 }

        runtime.model.retryRequested()

        try await until { tunnels.tunnels("evan@b").count == 2 }
        #expect(tunnels.tunnels("evan@a").count == 1)
    }

    /// Disable saves the whole machine list, and the store refuses names
    /// that differ only in case: the failure reaches the sidebar's panel
    /// error and the machine stays enabled.
    @Test func aDisableThatCannotBeSavedShowsAnError() throws {
        let defaults = LeoInMemoryDefaults()
        let clashing = [Support.host("a"), Support.host("A")]
        defaults.set(try JSONEncoder().encode(clashing), forKey: LeoHostStore.key)
        let runtime = try makeRuntime(machines: [], seedsHosts: false, defaults: defaults)
        defer { runtime.shutdown() }
        try #require(runtime.machines.configuration(for: .remote("a")) != nil)

        runtime.model.disableMachineRequested(.remote("a"))

        #expect(runtime.model.panelError?.hasPrefix("Couldn't disable a: ") == true)
        #expect(runtime.machines.configuration(for: .remote("a"))?.isEnabled == true)
    }

    // MARK: - Helpers

    private func makeRuntime(
        machines names: [String],
        disabled: Set<String> = [],
        seedsHosts: Bool = true,
        defaults: UserDefaults = LeoInMemoryDefaults(),
        tunnels: LeoFakeTunnels = LeoFakeTunnels(),
        feedsRemoteMachines: Bool = true,
        templates: LeoRecordingTemplateRunner = LeoRecordingTemplateRunner(),
        remoteDaemon: LeoRemoteDaemonFactory? = nil
    ) throws -> LeoRuntime {
        if seedsHosts { try Support.save(names.map { Support.host($0, enabled: !disabled.contains($0)) }, to: defaults) }
        let directory = LeoMachineTunnelTestSupport.localSocketDirectory
        let sleeper = LeoManualSleeper()
        return LeoRuntime(
            daemon: RuntimeTestDaemon(), cli: .recordingForTests(), activitySource: Self.quiet,
            defaults: defaults, templateFetchRunner: templates,
            machineRunner: LeoFakeHomeRunner(stdout: "/home/evan"),
            machineLegacySocketDirectory: directory,
            machineControlSocketDirectory: directory,
            makeTunnel: tunnels.factory,
            remoteDaemon: remoteDaemon ?? { host, _ in
                LeoMachineDaemon(daemon: LeoListingDaemon(names: ["\(host.displayName)-agent"]), activitySource: Self.quiet)
            },
            machineRetrySleep: { try await sleeper.sleep($0) },
            feedsRemoteMachines: feedsRemoteMachines
        )
    }

    /// What `LeoRuntime.start()` does once the local daemon is set up,
    /// without probing the real one.
    private func start(_ runtime: LeoRuntime) {
        runtime.feeds.start(pollable: false)
        runtime.machines.start(flavor: .socketEvents)
    }

    private func rows(_ runtime: LeoRuntime, _ machine: String) -> [String]? {
        runtime.model.snapshot(for: .remote(machine))?.rows.map(\.name)
    }

    /// Failed before it ever connected, or dropped after: either way down.
    private func isDown(_ runtime: LeoRuntime, _ machine: String) -> Bool {
        switch runtime.model.snapshot(for: .remote(machine))?.connectivity {
        case .failed?, .disconnected?: true
        default: false
        }
    }
}

/// Parks every client build until `open()`.
private actor LeoClientBuildGate {
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { parked.count }

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func open() {
        isOpen = true
        parked.forEach { $0.resume() }
        parked = []
    }
}

/// A machine whose daemon lists one agent and answers `machineStats`.
private struct LeoStatsListingDaemon: LeoDaemonClient {
    let cpu: Double
    private let listing = LeoListingDaemon(names: ["agent"])

    init(cpu: Double) { self.cpu = cpu }

    func machineStats() async throws -> LeoMachineStats {
        LeoMachineStats(
            sampledAt: Date(timeIntervalSince1970: 0), cpu: .init(percent: cpu, cores: 8),
            memory: .init(usedBytes: 1, totalBytes: 2), disk: .init(path: "/", usedBytes: 1, totalBytes: 2)
        )
    }

    func listAgents() async throws -> [LeoAgent] { try await listing.listAgents() }
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
