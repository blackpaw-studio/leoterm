import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

extension LeoMachineStats {
    static func make(cpu: Double? = 41, memory: Double = 0.58, disk: Double = 0.64) -> LeoMachineStats {
        LeoMachineStats(
            sampledAt: Date(timeIntervalSince1970: 1_000),
            cpu: .init(percent: cpu, cores: 8),
            memory: .init(usedBytes: Int64(memory * 1_000), totalBytes: 1_000),
            disk: .init(path: "/state", usedBytes: Int64(disk * 1_000), totalBytes: 1_000)
        )
    }
}

extension DaemonSession {
    /// A connected session whose daemon advertised `features`.
    static func connected(_ daemon: PairedDaemon, features: [String] = ["machine_stats"]) -> DaemonSession {
        var session = DaemonSession(daemon: daemon)
        session.connection = .connected
        session.features = LeoDaemonFeatures(features)
        return session
    }
}

@MainActor
struct DaemonsStatsTests {
    private func store(
        sessions: [DaemonSession], clock: TestClock<Duration>, style: LeoStatsStyle = .capsules,
        stats: @escaping @Sendable (DaemonConnection) async throws -> LeoMachineStats
    ) -> TestStore<Fleet.State, Fleet.Action> {
        @Shared(.appStorage("statsStyle")) var statsStyle = LeoStatsStyle.default
        $statsStyle.withLock { $0 = style }
        var state = Fleet.State()
        state.isActive = true
        state.sessions = IdentifiedArray(uniqueElements: sessions)
        let store = TestStore(initialState: state) { Fleet() } withDependencies: {
            $0.continuousClock = clock
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.machineStats = stats
        }
        store.exhaustivity = .off
        return store
    }

    @Test func pollsEveryFiveSecondsOnlyWhileTheListIsVisible() async {
        let clock = TestClock()
        let fetches = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in
            fetches.withValue { $0 += 1 }
            return .make()
        }

        // Not on screen: nothing is fetched.
        await clock.advance(by: .seconds(30))
        #expect(fetches.value == 0)

        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)
        #expect(fetches.value == 1)
        await clock.advance(by: .seconds(4))
        #expect(fetches.value == 1)
        await clock.advance(by: .seconds(1))
        await store.receive(\.statsLoaded)
        #expect(fetches.value == 2)

        await store.send(.statsVisibilityChanged(false))
        await clock.advance(by: .seconds(30))
        #expect(fetches.value == 2)
    }

    @Test func stopsPollingWhileTheAppIsInactive() async {
        let clock = TestClock()
        let fetches = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in
            fetches.withValue { $0 += 1 }
            return .make()
        }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)

        await store.send(.scenePhaseChanged(isActive: false))
        await clock.advance(by: .seconds(30))
        #expect(fetches.value == 1)
    }

    @Test func skipsDaemonsThatDoNotAdvertiseMachineStats() async {
        let clock = TestClock()
        let asked = LockIsolated<[String]>([])
        let store = store(
            sessions: [.connected(.dionysus), .connected(.hestia, features: ["agent_usage"])], clock: clock
        ) { connection in
            asked.withValue { $0.append(connection.daemonID) }
            return .make()
        }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)
        await clock.advance(by: .seconds(5))
        await store.receive(\.statsLoaded)

        #expect(Set(asked.value) == [PairedDaemon.dionysus.id])
        #expect(store.state.sessions[id: PairedDaemon.hestia.id]?.meters == nil)
    }

    @Test func oneDaemonFailingLeavesTheOthersPolling() async {
        let clock = TestClock()
        let store = store(sessions: [.connected(.dionysus), .connected(.hestia)], clock: clock) { connection in
            if connection.daemonID == PairedDaemon.dionysus.id { throw LeoDaemonError.timeout }
            return .make(cpu: 12)
        }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)
        await clock.advance(by: .seconds(5))
        await store.receive(\.statsLoaded)

        #expect(store.state.sessions[id: PairedDaemon.hestia.id]?.stats?.cpu?.percent == 12)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.stats == nil)
    }

    @Test func aFailedPollKeepsTheLastSampleAndTriesAgain() async {
        let clock = TestClock()
        let calls = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in
            calls.withValue { $0 += 1 }
            if calls.value == 2 { throw LeoDaemonError.timeout }
            return .make(cpu: Double(calls.value))
        }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)
        await clock.advance(by: .seconds(5))
        await clock.advance(by: .seconds(5))
        await store.receive(\.statsLoaded)

        #expect(calls.value == 3)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.stats?.cpu?.percent == 3)
    }

    @Test func machineStatsUnavailableShowsNoMeterAndStopsPollingThatDaemon() async {
        let clock = TestClock()
        let calls = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in
            calls.withValue { $0 += 1 }
            throw LeoDaemonError.daemon(code: LeoMachineStats.unavailableCode, message: "no stats", matches: [])
        }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsUnavailable)
        await clock.advance(by: .seconds(30))

        #expect(calls.value == 1)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.meters == nil)
    }

    @Test(arguments: ["unauthorized", "forbidden"])
    func aRejectedTokenClearsTheMetersAndStopsPollingUntilReconnect(code: String) async {
        let clock = TestClock()
        let calls = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in
            calls.withValue { $0 += 1 }
            if calls.value == 1 { return .make() }
            throw LeoDaemonError.daemon(code: code, message: "no", matches: [])
        }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)
        await clock.advance(by: .seconds(5))
        await store.receive(\.statsUnavailable)
        await clock.advance(by: .seconds(30))

        #expect(calls.value == 2)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.stats == nil)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.meters == nil)
    }

    @Test func hidingTheListClearsTheSamplesSoReopeningNeverShowsAnOldOne() async {
        let clock = TestClock()
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in .make() }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.meters != nil)

        await store.send(.statsVisibilityChanged(false))

        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.stats == nil)
    }

    @Test func aSampleThatCouldNotBeRefreshedForFifteenSecondsIsDropped() async {
        let clock = TestClock()
        let calls = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in
            calls.withValue { $0 += 1 }
            if calls.value == 1 { return .make() }
            throw LeoDaemonError.timeout
        }
        let id = PairedDaemon.dionysus.id
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)

        // Two missed polls (10s): the sample is still the latest there is.
        await clock.advance(by: .seconds(5))
        await store.receive(\.statsFailed)
        await clock.advance(by: .seconds(5))
        await store.receive(\.statsFailed)
        #expect(store.state.sessions[id: id]?.stats != nil)

        // The third (15s) drops it.
        await clock.advance(by: .seconds(5))
        await store.receive(\.statsFailed)
        #expect(store.state.sessions[id: id]?.stats == nil)
    }

    @Test func rePairingADaemonStopsItsStatsPolling() async {
        let clock = TestClock()
        let fetches = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock) { _ in
            fetches.withValue { $0 += 1 }
            return .make()
        }
        store.dependencies.pairedDaemons.save = { _ in }
        store.dependencies.daemonClient.events = { _ in AsyncThrowingStream { _ in } }
        await store.send(.statsVisibilityChanged(true))
        await store.receive(\.statsLoaded)

        await store.send(.daemonAdded(.dionysus))
        await clock.advance(by: .seconds(30))

        #expect(fetches.value == 1)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.stats == nil)
    }

    @Test func styleOffNeverPollsAndTurningItOffStopsPolling() async {
        let clock = TestClock()
        let fetches = LockIsolated(0)
        let store = store(sessions: [.connected(.dionysus)], clock: clock, style: .off) { _ in
            fetches.withValue { $0 += 1 }
            return .make()
        }
        await store.send(.statsVisibilityChanged(true))
        await clock.advance(by: .seconds(30))
        #expect(fetches.value == 0)

        await store.send(.statsStyleChanged(.bars))
        await store.receive(\.statsLoaded)
        #expect(fetches.value == 1)

        await store.send(.statsStyleChanged(.off))
        await clock.advance(by: .seconds(30))
        #expect(fetches.value == 1)
        #expect(store.state.statsStyle == .off)
    }

    @Test func startsPollingOnceHelloAdvertisesTheFlagAndStopsWhenTheStreamEnds() async {
        let clock = TestClock()
        let streams = StreamQueue(count: 1)
        let fetches = LockIsolated(0)
        var daemon = DaemonSession(daemon: .dionysus)
        daemon.connection = .offline
        let store = store(sessions: [daemon], clock: clock) { _ in
            fetches.withValue { $0 += 1 }
            return .make()
        }
        store.dependencies.daemonClient.events = { streams.next($0) }
        store.dependencies.daemonClient.fetchState = { _ in LeoObservedState(agents: []) }
        await store.send(.statsVisibilityChanged(true))
        await store.send(.connect(PairedDaemon.dionysus.id))

        streams[0].yield(.hello(seq: 1, at: nil, version: "0.57.0", serverTime: nil, features: ["machine_stats"]))
        await store.receive(\.connected)
        await store.receive(\.statsLoaded)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.stats != nil)

        streams[0].finish()
        await store.receive(\.streamEnded)
        await clock.advance(by: .seconds(5))
        #expect(fetches.value == 1)
        #expect(store.state.sessions[id: PairedDaemon.dionysus.id]?.stats == nil)
    }

    @Test func aNullCPUReadsAsADashAndLevelsFollowTheThresholds() {
        let meters = LeoMachineStats.make(cpu: nil, memory: 0.85, disk: 0.91).meters

        #expect(meters.map(\.kind) == [.cpu, .memory, .disk])
        #expect(meters.map(\.percentText) == ["—", "85%", "91%"])
        #expect(meters.map(\.level) == [.normal, .warning, .critical])
        #expect(meters[0].fraction == nil)
    }

    @Test func aFailedProbeBlanksOnlyItsOwnMeter() {
        let stats = LeoMachineStats(
            sampledAt: Date(), cpu: .init(percent: 23, cores: 4), memory: nil,
            disk: .init(path: "/", usedBytes: 47, totalBytes: 100)
        )

        #expect(stats.meters.map(\.percentText) == ["23%", "—", "47%"])
    }

    @Test func theDaemonsScreenReportsWhetherItIsOnScreen() async {
        let store = TestStore(initialState: Daemons.State()) { Daemons() }

        await store.send(.appeared)
        await store.receive(\.delegate.visibilityChanged, true)
        await store.send(.disappeared)
        await store.receive(\.delegate.visibilityChanged, false)
    }
}
