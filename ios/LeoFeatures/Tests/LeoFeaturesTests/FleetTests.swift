import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct FleetTests {
    @Test func mergesAgentsFromEveryDaemonGroupedWithAttentionFirst() async {
        let streams = [PairedDaemon.dionysus.id: StreamQueue(count: 1), PairedDaemon.hestia.id: StreamQueue(count: 1)]
        let snapshots: [String: LeoObservedState] = [
            PairedDaemon.dionysus.id: LeoObservedState(agents: [
                .make("zeus"), .make("apollo", activity: .working),
                .make("hermes", attention: .state(.finished, 3)), .make("ares", status: .stopped),
            ]),
            PairedDaemon.hestia.id: LeoObservedState(agents: [
                .make("athena", attention: .state(.needsInput, 1)), .make("ajax", attention: .state(.errored, 2)),
            ]),
        ]
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus, .hestia])) {
            Fleet()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.events = { streams[$0.daemonID]!.next($0) }
            $0.daemonClient.fetchState = { snapshots[$0.daemonID]! }
        }

        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isActive = true
            $0.sessions[id: PairedDaemon.dionysus.id]?.connection = .connecting
            $0.sessions[id: PairedDaemon.hestia.id]?.connection = .connecting
        }
        for daemon in [PairedDaemon.dionysus, .hestia] {
            streams[daemon.id]![0].yield(.hello(seq: 1, at: nil, version: "0.36.0", serverTime: nil))
            await store.receive(\.connected) { $0.sessions[id: daemon.id]?.connection = .connected }
            await store.receive(\.snapshotLoaded) {
                $0.sessions[id: daemon.id]?.agents = IdentifiedArray(uniqueElements: snapshots[daemon.id]!.agents.map(Agent.init))
            }
        }

        let sections = store.state.sections
        #expect(sections.map(\.daemon.name) == ["hestia", "dionysus"])
        #expect(sections[0].agents.map(\.name) == ["athena", "ajax"])
        #expect(sections[1].agents.map(\.name) == ["hermes", "apollo", "zeus", "ares"])
        #expect(store.state.attentionCount == 3)

        await store.send(.scenePhaseChanged(isActive: false)) {
            $0.isActive = false
            for id in $0.sessions.ids { $0.sessions[id: id]?.connection = .offline }
        }
    }

    @Test func appliesLiveEventsAndIgnoresStaleAttention() async {
        let streams = StreamQueue(count: 1)
        let fetches = LockIsolated(0)
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus])) {
            Fleet()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.events = { streams.next($0) }
            $0.daemonClient.fetchState = { _ in
                fetches.withValue { $0 += 1 }
                return fetches.value == 1
                    ? LeoObservedState(agents: [.make("zeus", attention: .state(.working, 5))])
                    : LeoObservedState(agents: [.make("zeus", attention: .state(.working, 5)), .make("hera", harness: "codex")])
            }
        }
        let id = PairedDaemon.dionysus.id
        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isActive = true
            $0.sessions[id: id]?.connection = .connecting
        }
        streams[0].yield(.hello(seq: 1, at: nil, version: nil, serverTime: nil))
        await store.receive(\.connected) { $0.sessions[id: id]?.connection = .connected }
        await store.receive(\.snapshotLoaded) {
            $0.sessions[id: id]?.agents = [Agent(.make("zeus", attention: .state(.working, 5)))]
        }

        streams[0].yield(.agentActivity(seq: 2, at: nil, agent: "zeus", activity: .idle, currentAction: nil, attention: .state(.needsInput, 6)))
        await store.receive(\.eventReceived) {
            $0.sessions[id: id]?.agents[id: "zeus"]?.attention = .state(.needsInput, 6)
        }
        streams[0].yield(.agentActivity(seq: 3, at: nil, agent: "zeus", activity: .working, currentAction: nil, attention: .state(.working, 4)))
        await store.receive(\.eventReceived) {
            $0.sessions[id: id]?.agents[id: "zeus"]?.activity = .working
        }
        streams[0].yield(.agentStopped(seq: 4, at: nil, agent: "zeus", wakeOnMessage: false))
        await store.receive(\.eventReceived) {
            $0.sessions[id: id]?.agents[id: "zeus"]?.status = .stopped
            $0.sessions[id: id]?.agents[id: "zeus"]?.activity = .unknown
        }
        streams[0].yield(.agentStateChanged(seq: 5, at: nil, agent: "zeus", status: .running, restarts: 1, wakeOnMessage: nil))
        await store.receive(\.eventReceived) {
            $0.sessions[id: id]?.agents[id: "zeus"]?.status = .running
        }

        // A spawn refetches the snapshot, which carries the harness the
        // event lacks.
        let spawned = LeoAgent(
            name: "hera", template: "coding", repo: nil, workspace: nil, branch: nil, canonicalPath: nil,
            status: .starting, startedAt: nil, restarts: 0, stoppedReason: nil, wakeOnMessage: nil
        )
        streams[0].yield(.agentSpawned(seq: 6, at: nil, agent: spawned))
        await store.receive(\.eventReceived) {
            $0.sessions[id: id]?.agents.append(Agent(name: "hera", status: .starting, template: "coding"))
        }
        await store.receive(\.snapshotLoaded) {
            // The snapshot is authoritative, except for attention it
            // reports at an older revision than one already seen.
            $0.sessions[id: id]?.agents[id: "zeus"]?.activity = .idle
            $0.sessions[id: id]?.agents[id: "hera"] = Agent(.make("hera", harness: "codex"))
        }
        #expect(store.state.sessions[id: id]?.agents[id: "zeus"]?.attention == .state(.needsInput, 6))

        await store.send(.scenePhaseChanged(isActive: false)) {
            $0.isActive = false
            $0.sessions[id: id]?.connection = .offline
        }
    }

    @Test func aSequenceGapRefetchesTheSnapshot() async {
        let streams = StreamQueue(count: 1)
        let fetches = LockIsolated(0)
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus])) {
            Fleet()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.events = { streams.next($0) }
            $0.daemonClient.fetchState = { _ in
                fetches.withValue { $0 += 1 }
                return LeoObservedState(agents: fetches.value == 1 ? [] : [.make("zeus")])
            }
        }
        let id = PairedDaemon.dionysus.id
        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isActive = true
            $0.sessions[id: id]?.connection = .connecting
        }
        streams[0].yield(.hello(seq: 10, at: nil, version: nil, serverTime: nil))
        await store.receive(\.connected) { $0.sessions[id: id]?.connection = .connected }
        await store.receive(\.snapshotLoaded)
        streams[0].yield(.other(seq: 13, type: "task_run_started"))
        await store.receive(\.snapshotLoaded) {
            $0.sessions[id: id]?.agents = [Agent(.make("zeus"))]
        }
        await store.receive(\.eventReceived)
        #expect(fetches.value == 2)

        await store.send(.scenePhaseChanged(isActive: false)) {
            $0.isActive = false
            $0.sessions[id: id]?.connection = .offline
        }
    }

    @Test func reconnectsWithExponentialBackoffOnTheInjectedClock() async {
        let clock = TestClock()
        let streams = StreamQueue(count: 4)
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus])) {
            Fleet()
        } withDependencies: {
            $0.continuousClock = clock
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.events = { streams.next($0) }
            $0.daemonClient.fetchState = { _ in LeoObservedState(agents: []) }
        }
        let id = PairedDaemon.dionysus.id
        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isActive = true
            $0.sessions[id: id]?.connection = .connecting
        }

        streams[0].finish(throwing: LeoDaemonError.transport("The network connection was lost."))
        await store.receive(\.streamEnded) {
            $0.sessions[id: id]?.failures = 1
            $0.sessions[id: id]?.connection = .reconnecting(attempt: 1, reason: "The network connection was lost.")
        }
        await clock.advance(by: .milliseconds(999))
        #expect(streams.opened.value.count == 1)
        await clock.advance(by: .milliseconds(1))
        await store.receive(\.connect)

        streams[1].finish()
        await store.receive(\.streamEnded) {
            $0.sessions[id: id]?.failures = 2
            $0.sessions[id: id]?.connection = .reconnecting(attempt: 2, reason: "Connection closed")
        }
        await clock.advance(by: .seconds(1))
        #expect(streams.opened.value.count == 2)
        await clock.advance(by: .seconds(1))
        await store.receive(\.connect)

        // A hello resets the backoff.
        streams[2].yield(.hello(seq: 1, at: nil, version: nil, serverTime: nil))
        await store.receive(\.connected) {
            $0.sessions[id: id]?.failures = 0
            $0.sessions[id: id]?.connection = .connected
        }
        await store.receive(\.snapshotLoaded)
        streams[2].finish()
        await store.receive(\.streamEnded) {
            $0.sessions[id: id]?.failures = 1
            $0.sessions[id: id]?.connection = .reconnecting(attempt: 1, reason: "Connection closed")
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.connect)

        await store.send(.scenePhaseChanged(isActive: false)) {
            $0.isActive = false
            $0.sessions[id: id]?.failures = 0
            $0.sessions[id: id]?.connection = .offline
        }
    }

    @Test func backoffDoublesUpToThirtySeconds() {
        #expect((1...7).map(Fleet.backoff) == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }

    @Test func aRejectedTokenStopsRetrying() async {
        let streams = StreamQueue(count: 1)
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus])) {
            Fleet()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "revoked") }
            $0.daemonClient.events = { streams.next($0) }
        }
        let id = PairedDaemon.dionysus.id
        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isActive = true
            $0.sessions[id: id]?.connection = .connecting
        }
        streams[0].finish(throwing: LeoDaemonError.daemon(code: "unauthorized", message: "HTTP 401", matches: []))
        await store.receive(\.streamEnded) {
            $0.sessions[id: id]?.connection = .unauthorized("This device's token was rejected. Pair it again.")
        }
    }

    @Test func aMissingTokenAsksToPairAgain() async {
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus])) {
            Fleet()
        } withDependencies: {
            $0.secrets.load = { _ in nil }
        }
        let id = PairedDaemon.dionysus.id
        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isActive = true
            $0.sessions[id: id]?.connection = .connecting
        }
        await store.receive(\.streamEnded) {
            $0.sessions[id: id]?.connection = .unauthorized("No saved token for this daemon. Pair it again.")
        }
    }

    @Test func addingAndRemovingDaemonsPersistsTheListAndTheKeychain() async {
        let saved = LockIsolated<[[PairedDaemon]]>([])
        let deleted = LockIsolated<[String]>([])
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus])) {
            Fleet()
        } withDependencies: {
            $0.pairedDaemons.save = { daemons in saved.withValue { $0.append(daemons) } }
            $0.secrets.delete = { id in deleted.withValue { $0.append(id) } }
        }
        await store.send(.daemonAdded(.hestia)) {
            $0.sessions.append(DaemonSession(daemon: .hestia))
        }
        await store.send(.daemonRemoved(PairedDaemon.dionysus.id)) {
            $0.sessions.remove(id: PairedDaemon.dionysus.id)
        }
        #expect(saved.value == [[.dionysus, .hestia], [.hestia]])
        #expect(deleted.value == [PairedDaemon.dionysus.id])
    }

    @Test func rePairingADaemonReplacesItInPlace() async {
        var updated = PairedDaemon.dionysus
        updated.deviceID = "dev-9"
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus, .hestia])) {
            Fleet()
        } withDependencies: {
            $0.pairedDaemons.save = { _ in }
        }
        await store.send(.daemonAdded(updated)) {
            $0.sessions[id: updated.id] = DaemonSession(daemon: updated)
        }
        #expect(store.state.sessions.map(\.daemon) == [updated, .hestia])
    }

    @Test func loadsThePairedDaemonsAtLaunch() async {
        let store = TestStore(initialState: Fleet.State()) {
            Fleet()
        } withDependencies: {
            $0.pairedDaemons.load = { [.hestia] }
        }
        await store.send(.task)
        await store.receive(\.daemonsLoaded) {
            $0.sessions = [DaemonSession(daemon: .hestia)]
        }
    }
}
