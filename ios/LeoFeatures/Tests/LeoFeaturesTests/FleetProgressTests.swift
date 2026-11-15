import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct FleetProgressTests {
    static let id = PairedDaemon.dionysus.id
    nonisolated static let now = progressEpoch.addingTimeInterval(60)

    static func store(agents: [LeoObservedAgent] = []) -> TestStore<Fleet.State, Fleet.Action> {
        var state = Fleet.State(daemons: [.dionysus])
        state.sessions[id: id]?.applySnapshot(LeoObservedState(agents: agents), now: now)
        let store = TestStore(initialState: state) {
            Fleet()
        } withDependencies: {
            $0.progressNow = { now }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
        }
        store.exhaustivity = .off
        return store
    }

    static func event(_ seq: Int, _ id: String, _ task: LeoAgentTask?, agent: String = "zeus") -> LeoObserveEvent {
        .agentTaskChanged(seq: seq, at: nil, agent: agent, id: id, task: task)
    }

    @Test func snapshotTasksLandOnTheAgentWithoutAFinish() async {
        let store = Self.store(agents: [.make("zeus", tasks: [.make("build", percent: 5)])])
        #expect(store.state.sessions[id: Self.id]?.agents[id: "zeus"]?.tasks.map(\.id) == ["build"])
        await store.send(.snapshotLoaded(Self.id, LeoObservedState(agents: [.make("zeus", tasks: [.make("build", percent: 5, state: .failed, endedAt: Self.now)])])))
        // A replayed failure is silent.
    }

    @Test func aTaskEventUpdatesTheAgentsTasks() async {
        let store = Self.store(agents: [.make("zeus", tasks: [])])
        await store.send(.eventReceived(Self.id, Self.event(1, "build", .make("build", percent: 30))))
        #expect(store.state.sessions[id: Self.id]?.agents[id: "zeus"]?.tasks.map(\.percent) == [30])
        await store.send(.eventReceived(Self.id, Self.event(2, "build", nil)))
        #expect(store.state.sessions[id: Self.id]?.agents[id: "zeus"]?.tasks.isEmpty == true)
    }

    @Test func aLiveFailureReportsAFinishAndAReplayDoesNot() async {
        let store = Self.store(agents: [.make("zeus", tasks: [.make("build", percent: 30)])])
        let failed = LeoAgentTask.make("build", percent: 30, state: .failed, endedAt: Self.now, revision: 2)
        await store.send(.eventReceived(Self.id, Self.event(1, "build", failed)))
        await store.receive(\.taskFinished)
        await store.send(.eventReceived(Self.id, Self.event(2, "build", failed)))
    }

    @Test func anEventForAnUnknownAgentIsIgnored() async {
        let store = Self.store(agents: [.make("zeus", tasks: [])])
        await store.send(.eventReceived(Self.id, Self.event(1, "build", .make("build"), agent: "ghost")))
        #expect(store.state.sessions[id: Self.id]?.agents[id: "ghost"] == nil)
    }

    @Test func theAgentStoppingClearsItsTasks() async {
        let store = Self.store(agents: [.make("zeus", tasks: [.make("build", percent: 30)])])
        await store.send(.eventReceived(Self.id, .agentStopped(seq: 1, at: nil, agent: "zeus", wakeOnMessage: nil)))
        #expect(store.state.sessions[id: Self.id]?.agents[id: "zeus"]?.tasks.isEmpty == true)
    }

    @Test func dismissCallsTheDaemonForThatTask() async {
        let dismissed = LockIsolated<[String]>([])
        let store = Self.store(agents: [.make("zeus", tasks: [.make("build", state: .failed, endedAt: Self.now)])])
        store.dependencies.daemonClient.dismissTask = { connection, agent, id in
            dismissed.withValue { $0.append("\(connection.daemonID) \(agent) \(id)") }
        }
        await store.send(.dismissTask(Self.id, agent: "zeus", id: "build"))
        await store.finish()
        #expect(dismissed.value == ["d-dionysus zeus build"])
        #expect(store.state.taskDismissError == nil)
    }

    @Test(arguments: [LeoAgentTask.State.succeeded, .cancelled])
    func dismissCallsTheDaemonForAnyEndedTask(state: LeoAgentTask.State) async {
        let dismissed = LockIsolated<[String]>([])
        let store = Self.store(agents: [.make("zeus", tasks: [.make("build", state: state, endedAt: Self.now)])])
        store.dependencies.daemonClient.dismissTask = { _, agent, id in
            dismissed.withValue { $0.append("\(agent) \(id)") }
        }
        await store.send(.dismissTask(Self.id, agent: "zeus", id: "build"))
        await store.finish()
        #expect(dismissed.value == ["zeus build"])
        #expect(store.state.taskDismissError == nil)
    }

    @Test func aGoneTaskIsNotAnError() async {
        let store = Self.store()
        store.dependencies.daemonClient.dismissTask = { _, _, _ in throw LeoAgentTaskError.notFound }
        await store.send(.dismissTask(Self.id, agent: "zeus", id: "build"))
        await store.finish()
        #expect(store.state.taskDismissError == nil)
    }

    @Test func aRefusedDismissSurfacesTheReason() async {
        let store = Self.store()
        store.dependencies.daemonClient.dismissTask = { _, _, _ in throw LeoAgentTaskError.notDismissable(reason: "still running") }
        await store.send(.dismissTask(Self.id, agent: "zeus", id: "build"))
        await store.receive(\.taskDismissFailed)
        #expect(store.state.taskDismissError == "still running")
        await store.send(.taskDismissErrorShown)
        #expect(store.state.taskDismissError == nil)
    }

    @Test func thePanelListsFailedThenRunningAcrossAgentsAndSkipsEndedOnes() {
        var state = Fleet.State(daemons: [.dionysus])
        state.sessions[id: Self.id]?.applySnapshot(LeoObservedState(agents: [
            .make("zeus", tasks: [
                .make("a", percent: 62, updatedAt: progressEpoch.addingTimeInterval(10)),
                .make("done", state: .succeeded, endedAt: progressEpoch),
            ]),
            .make("apollo", tasks: [
                .make("b", state: .failed, endedAt: progressEpoch),
                .make("c", updatedAt: progressEpoch.addingTimeInterval(20)),
            ]),
        ]), now: Self.now)
        let rows = state.taskPanelRows
        #expect(rows.map(\.task.id) == ["b", "c", "a"])
        #expect(rows.map(\.ref.name) == ["apollo", "apollo", "zeus"])
        #expect(state.taskPanelHeader == "Tasks 3 · 62%")
    }

    @Test func anOpenChatsPanelShowsOnlyThatAgentsTasks() {
        var state = Fleet.State(daemons: [.dionysus])
        state.sessions[id: Self.id]?.applySnapshot(LeoObservedState(agents: [
            .make("zeus", tasks: [.make("a", percent: 62)]),
            .make("apollo", tasks: [.make("b", state: .failed, endedAt: progressEpoch), .make("c")]),
        ]), now: Self.now)
        let apollo = AgentRef(daemonID: Self.id, name: "apollo")
        #expect(state.taskPanelRows(scopedTo: apollo).map(\.task.id) == ["b", "c"])
        #expect(state.taskPanelHeader(scopedTo: apollo) == "Tasks 2")
        #expect(state.taskPanelRows(scopedTo: AgentRef(daemonID: Self.id, name: "hera")).isEmpty)
        #expect(state.taskPanelRows(scopedTo: nil).count == 3)
    }

    @Test func theCollapsedHeaderCarriesTheLeadRunningPercent() {
        var state = Fleet.State(daemons: [.dionysus])
        state.sessions[id: Self.id]?.applySnapshot(LeoObservedState(agents: [.make("zeus", tasks: [.make("a", percent: 62), .make("b")])]), now: Self.now)
        #expect(state.taskPanelHeader == "Tasks 2 · 62%")
    }

    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "FleetProgressTests.\(UUID().uuidString)")!
    }

    @Test func thePanelStartsExpandedAtRegularWidthAndCollapsedAtCompact() async {
        let store = withDependencies { $0.defaultAppStorage = Self.freshDefaults() } operation: { Self.store() }
        #expect(store.state.isProgressPanelCollapsed == false)
        await store.send(.widthClassChanged(isCompact: true))
        #expect(store.state.isProgressPanelCollapsed == true)
        await store.send(.widthClassChanged(isCompact: false))
        #expect(store.state.isProgressPanelCollapsed == false)
    }

    @Test func togglingFlipsWhatIsShownAndThatChoiceOutlivesWidthChanges() async {
        let store = withDependencies { $0.defaultAppStorage = Self.freshDefaults() } operation: { Self.store() }
        await store.send(.widthClassChanged(isCompact: true))
        await store.send(.progressPanelToggled)
        #expect(store.state.isProgressPanelCollapsed == false)
        await store.send(.widthClassChanged(isCompact: false))
        #expect(store.state.isProgressPanelCollapsed == false)
        await store.send(.progressPanelToggled)
        #expect(store.state.isProgressPanelCollapsed == true)
        await store.send(.widthClassChanged(isCompact: true))
        #expect(store.state.isProgressPanelCollapsed == true)
    }

    @Test func aRememberedChoiceIsRestoredFromTheStoredDefault() {
        let defaults = Self.freshDefaults()
        defaults.set(false, forKey: "progressPanelCollapsed")
        var state = withDependencies { $0.defaultAppStorage = defaults } operation: { Fleet.State(daemons: [.dionysus]) }
        state.isCompactWidth = true
        #expect(state.isProgressPanelCollapsed == false)

        defaults.set(true, forKey: "progressPanelCollapsed")
        let collapsed = withDependencies { $0.defaultAppStorage = defaults } operation: { Fleet.State(daemons: [.dionysus]) }
        #expect(collapsed.isProgressPanelCollapsed == true)
    }

    // MARK: Progress clock

    @Test func theProgressClockTicksEverySecondWhileATaskRuns() async {
        let clock = TestClock()
        let current = LockIsolated(Self.now)
        var state = Fleet.State(daemons: [.dionysus])
        state.isActive = true
        let store = TestStore(initialState: state) {
            Fleet()
        } withDependencies: {
            $0.continuousClock = clock
            $0.progressNow = { current.value }
        }
        store.exhaustivity = .off
        await store.send(.snapshotLoaded(Self.id, LeoObservedState(agents: [.make("zeus", tasks: [.make("build", percent: 5)])])))
        #expect(store.state.progressClock == Self.now)
        current.setValue(Self.now.addingTimeInterval(1))
        await clock.advance(by: .seconds(1))
        await store.receive(\.progressTicked)
        #expect(store.state.progressClock == Self.now.addingTimeInterval(1))

        await store.send(.snapshotLoaded(Self.id, LeoObservedState(agents: [.make("zeus", tasks: [])])))
        #expect(store.state.isProgressTicking == false)
        current.setValue(Self.now.addingTimeInterval(5))
        await clock.advance(by: .seconds(5))
        #expect(store.state.progressClock == Self.now.addingTimeInterval(1))
    }

    @Test func theProgressClockStopsWhenTheAppGoesInactive() async {
        let clock = TestClock()
        var state = Fleet.State(daemons: [.dionysus])
        state.isActive = true
        let store = TestStore(initialState: state) {
            Fleet()
        } withDependencies: {
            $0.continuousClock = clock
            $0.progressNow = { Self.now }
        }
        store.exhaustivity = .off
        await store.send(.snapshotLoaded(Self.id, LeoObservedState(agents: [.make("zeus", tasks: [.make("build", percent: 5)])])))
        await store.send(.scenePhaseChanged(isActive: false))
        #expect(store.state.isProgressTicking == false)
    }

    @Test func aTaskFreeFleetNeverStartsTheClock() async {
        let store = Self.store(agents: [.make("zeus", tasks: [.make("done", state: .succeeded, endedAt: Self.now)])])
        await store.send(.snapshotLoaded(Self.id, LeoObservedState(agents: [.make("zeus", tasks: [])])))
        #expect(store.state.isProgressTicking == false)
    }

    // MARK: Reconnect stays silent

    @Test(arguments: ["boot-1", "boot-2"])
    func aReconnectNeverReportsAFinish(_ bootID: String) async {
        var state = Fleet.State(daemons: [.dionysus])
        state.sessions[id: Self.id]?.applySnapshot(
            LeoObservedState(agents: [.make("zeus", tasks: [.make("build", state: .failed, endedAt: progressEpoch)])]), bootID: "boot-1", now: Self.now
        )
        let store = TestStore(initialState: state) {
            Fleet()
        } withDependencies: {
            $0.progressNow = { Self.now }
        }
        let replay = LeoObservedState(agents: [.make("zeus", tasks: [.make("build", state: .failed, endedAt: Self.now, revision: 3)])])
        // Exhaustive: any `taskFinished` the reconnect sent would fail here.
        var expected = state.sessions[id: Self.id]!
        expected.connection = .connected
        expected.applySnapshot(replay, bootID: bootID, now: Self.now)
        await store.send(.connected(Self.id, bootID: bootID, features: LeoDaemonFeatures([]), replay)) {
            $0.sessions[id: Self.id] = expected
        }
    }
}
