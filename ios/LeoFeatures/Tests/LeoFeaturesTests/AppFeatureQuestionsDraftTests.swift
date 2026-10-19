import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

/// Unsent questions answers outlive the thread state, which opening another chat replaces.
@MainActor
struct AppFeatureQuestionsDraftTests {
    @Test func aQuestionsDraftSurvivesOpeningAnotherChatAndComingBack() async throws {
        let hera = AgentRef(daemonID: AppFeatureChatTests.zeus.daemonID, name: "hera")
        var state = AppFeatureChatTests.connected()
        state.fleet.sessions[0].agents = [Agent(.make("zeus")), Agent(.make("hera"))]
        let questions = ChatThreadQuestionsTests.questions
        let draft = LeoChatQuestionsDraft(questions: questions).choosing("Swift", question: "q1")
        var thread = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        thread.messages = [try ChatThreadQuestionsTests.questionsCard()]
        thread.questionsDrafts["01"] = draft
        state.chat = thread
        let store = TestStore(initialState: state) { AppFeature() }

        await store.send(.chatOpened(hera)) {
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "hera", live: Agent(.make("hera")))
            $0.parkedQuestionsDrafts[AppFeatureChatTests.zeus] = ["01": draft]
        }
        await store.send(.chatOpened(AppFeatureChatTests.zeus)) {
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
            $0.chat?.questionsDrafts = ["01": draft]
            $0.parkedQuestionsDrafts = [:]
        }
        // Opening an agent's detail parks it too.
        await store.send(.agentTapped(AppFeatureChatTests.zeus)) {
            $0.chat = nil
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
            $0.parkedQuestionsDrafts[AppFeatureChatTests.zeus] = ["01": draft]
        }
    }
}
