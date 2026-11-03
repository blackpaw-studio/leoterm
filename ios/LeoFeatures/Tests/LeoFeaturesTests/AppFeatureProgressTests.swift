import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AppFeatureProgressTests {
    static let ref = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")
    static let failed = LeoAgentTask.make("build", title: "Xcode build", state: .failed, endedAt: progressEpoch)
    static let done = LeoAgentTask.make("build", title: "Xcode build", state: .succeeded, endedAt: progressEpoch)

    static func store(
        selectedTab: AppTab = .agents, detail: Bool = false, thread: Bool = false, notificationsOn: Bool = true, posted: LockIsolated<[ProgressNotification]>
    ) -> TestStore<AppFeature.State, AppFeature.Action> {
        var state = AppFeature.State()
        state.fleet = Fleet.State(daemons: [.dionysus])
        state.fleet.isActive = true
        state.fleet.sessions[id: ref.daemonID]?.agents = [Agent(name: "zeus", displayName: "Zeus")]
        state.selectedTab = selectedTab
        if detail, let agent = state.fleet.agent(ref) {
            state.detail = AgentDetail.State(daemon: .dionysus, agent: agent, connection: .connected)
        }
        if thread {
            var chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: nil)
            chat.isOnScreen = true
            state.chat = chat
        }
        state.push.$isEnabled.withLock { $0 = notificationsOn }
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.progressNotifier.post = { notification in posted.withValue { $0.append(notification) } }
        }
        store.exhaustivity = .off
        return store
    }

    @Test func aFinishPostsANotificationNamingTheAgentAndTask() async {
        let posted = LockIsolated<[ProgressNotification]>([])
        let store = Self.store(posted: posted)
        await store.send(.fleet(.taskFinished(Self.ref.daemonID, LeoTaskFinish(agent: "zeus", task: Self.failed))))
        await store.finish()
        #expect(posted.value == [ProgressNotification(ref: Self.ref, agentName: "Zeus", taskTitle: "Xcode build", outcome: .failed)])
    }

    @Test func aSuccessPostsASucceededNotification() async {
        let posted = LockIsolated<[ProgressNotification]>([])
        let store = Self.store(posted: posted)
        await store.send(.fleet(.taskFinished(Self.ref.daemonID, LeoTaskFinish(agent: "zeus", task: Self.done))))
        await store.finish()
        #expect(posted.value.map(\.outcome) == [.succeeded])
    }

    @Test func itIsSuppressedWhileThatAgentsDetailIsOnScreen() async {
        let posted = LockIsolated<[ProgressNotification]>([])
        let store = Self.store(detail: true, posted: posted)
        await store.send(.fleet(.taskFinished(Self.ref.daemonID, LeoTaskFinish(agent: "zeus", task: Self.done))))
        await store.finish()
        #expect(posted.value.isEmpty)
    }

    @Test func itIsNotSuppressedWhenTheDetailIsSelectedButAnotherTabIsShowing() async {
        let posted = LockIsolated<[ProgressNotification]>([])
        let store = Self.store(selectedTab: .machines, detail: true, posted: posted)
        await store.send(.fleet(.taskFinished(Self.ref.daemonID, LeoTaskFinish(agent: "zeus", task: Self.done))))
        await store.finish()
        #expect(posted.value.count == 1)
    }

    @Test func itIsSuppressedWhileThatAgentsThreadIsOnScreen() async {
        let posted = LockIsolated<[ProgressNotification]>([])
        let store = Self.store(selectedTab: .chats, thread: true, posted: posted)
        await store.send(.fleet(.taskFinished(Self.ref.daemonID, LeoTaskFinish(agent: "zeus", task: Self.done))))
        await store.finish()
        #expect(posted.value.isEmpty)
    }

    @Test func itIsNotPostedWhenTheUserTurnedNotificationsOff() async {
        let posted = LockIsolated<[ProgressNotification]>([])
        let store = Self.store(notificationsOn: false, posted: posted)
        await store.send(.fleet(.taskFinished(Self.ref.daemonID, LeoTaskFinish(agent: "zeus", task: Self.done))))
        await store.finish()
        #expect(posted.value.isEmpty)
    }
}
