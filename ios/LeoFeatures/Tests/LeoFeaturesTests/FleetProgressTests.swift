import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct FleetProgressTests {
    static let id = PairedDaemon.dionysus.id
    static let now = progressEpoch.addingTimeInterval(60)

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
        #expect(rows.map(\.agent.name) == ["apollo", "apollo", "zeus"])
        #expect(state.taskPanelHeader == "Tasks 3 · 62%")
    }

    @Test func theCollapsedHeaderCarriesTheLeadRunningPercent() {
        var state = Fleet.State(daemons: [.dionysus])
        state.sessions[id: Self.id]?.applySnapshot(LeoObservedState(agents: [.make("zeus", tasks: [.make("a", percent: 62), .make("b")])]), now: Self.now)
        #expect(state.taskPanelHeader == "Tasks 2 · 62%")
    }

    @Test func thePanelStartsExpandedAndRemembersCollapsing() async {
        @Shared(.progressPanelCollapsed) var collapsed
        $collapsed.withLock { $0 = false }
        let store = Self.store()
        await store.send(.progressPanelToggled)
        #expect(collapsed == true)
        await store.send(.progressPanelToggled)
        #expect(collapsed == false)
    }
}
