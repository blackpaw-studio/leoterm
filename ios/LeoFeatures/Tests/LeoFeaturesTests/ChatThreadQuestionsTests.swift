import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

/// A questions card in the thread: drafts, submit, dismiss, and what a settled card clears.
@MainActor
struct ChatThreadQuestionsTests {
    static let questions = [
        LeoChatQuestion(id: "q1", header: "Library", question: "Which library?", options: [
            LeoChatOption(value: "Swift", label: "Swift"), LeoChatOption(value: "Zig", label: "Zig")
        ]),
        LeoChatQuestion(id: "q2", header: "Scope", question: "Which scopes?", multi: true, options: [
            LeoChatOption(value: "A", label: "A"), LeoChatOption(value: "B", label: "B")
        ])
    ]

    static func questionsCard(
        state: String = "open", answer: LeoChatAnswer? = nil, closedReason: String? = nil
    ) throws -> LeoChatMessage {
        .make(
            "01", "Questions", kind: .ask, state: state, answer: answer, input: try LeoChatInput(questions: questions),
            closedReason: closedReason
        )
    }

    static func questionsStore(
        _ card: LeoChatMessage, drafts: [String: LeoChatQuestionsDraft] = [:], refreshed: LeoChatMessage? = nil,
        answerQuestions: @escaping @Sendable (String, [String: LeoChatAnswer]) async throws
            -> LeoChatMessage? = { _, _ in nil },
        dismiss: @escaping @Sendable (String) async throws -> LeoChatMessage? = { _ in nil }
    ) -> TestStoreOf<ChatThread> {
        var state = ChatThreadTests.state()
        state.messages = [card]
        state.questionsDrafts = drafts
        return TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            ChatThreadTests.withSecrets(&$0)
            $0.chatClient.answerQuestions = { _, agent, id, answers in
                #expect(agent == "zeus")
                return try await answerQuestions(id, answers)
            }
            $0.chatClient.dismiss = { _, agent, id in
                #expect(agent == "zeus")
                return try await dismiss(id)
            }
            $0.chatClient.messages = { _, _, _ in LeoChatPage(messages: [refreshed ?? card], hasMore: false) }
        }
    }

    @Test func choosingAQuestionOptionUpdatesOnlyItsDraft() async throws {
        let store = Self.questionsStore(try Self.questionsCard())
        let empty = LeoChatQuestionsDraft(questions: Self.questions)

        await store.send(.questionChoiceTapped(messageID: "01", questionID: "q1", value: "Swift")) {
            $0.questionsDrafts["01"] = empty.choosing("Swift", question: "q1")
        }
        await store.send(.questionTextChanged(messageID: "01", questionID: "q2", "docs too")) {
            $0.questionsDrafts["01"] = empty.choosing("Swift", question: "q1").withText("docs too", question: "q2")
        }
        let draft = store.state.questionsDrafts["01"]
        #expect(draft?.values(for: "q1") == ["Swift"])
        #expect(draft?.values(for: "q2") == [])
        // Unknown cards take no input.
        await store.send(.questionChoiceTapped(messageID: "missing", questionID: "q1", value: "Zig"))
        await store.send(.questionTextChanged(messageID: "missing", questionID: "q1", "x"))
    }

    @Test func aCompleteDraftIsRequiredToSubmit() async throws {
        let calls = LockIsolated(0)
        let draft = LeoChatQuestionsDraft(questions: Self.questions).choosing("Swift", question: "q1")
        let store = Self.questionsStore(try Self.questionsCard(), drafts: ["01": draft]) { _, _ in
            calls.withValue { $0 += 1 }
            return nil
        }
        await store.send(.questionsSubmitTapped(messageID: "01"))
        #expect(calls.value == 0)
    }

    @Test func submittingQuestionsSendsThePayloadAndMergesTheCard() async throws {
        let draft = LeoChatQuestionsDraft(questions: Self.questions)
            .choosing("Swift", question: "q1").choosing("B", question: "q2").withText(" docs ", question: "q2")
        let payload = draft.answersPayload
        let card = try Self.questionsCard()
        let answered = try Self.questionsCard(state: "answered", answer: LeoChatAnswer(answers: payload))
        let sent = LockIsolated<[[String: LeoChatAnswer]]>([])
        let store = Self.questionsStore(card, drafts: ["01": draft]) { id, answers in
            #expect(id == "01")
            sent.withValue { $0.append(answers) }
            return answered
        }

        await store.send(.questionsSubmitTapped(messageID: "01")) { $0.answering = ["01"] }
        await store.receive(\.questionsResponse) {
            $0.answering = []
            $0.questionsDrafts = [:]
            $0.messages[id: "01"] = answered
        }
        #expect(sent.value == [payload])
        #expect(sent.value.first?["q2"] == LeoChatAnswer(values: ["B"], text: "docs"))
    }

    @Test func aSettledQuestionsCardRefreshesWithoutAnAlert() async throws {
        let draft = LeoChatQuestionsDraft(questions: Self.questions)
            .choosing("Swift", question: "q1").choosing("A", question: "q2")
        let timedOut = try Self.questionsCard(state: "expired", closedReason: "timeout")
        let store = Self.questionsStore(
            try Self.questionsCard(), drafts: ["01": draft], refreshed: timedOut,
            answerQuestions: { _, _ in throw LeoChatAnswerError.settled }
        )

        await store.send(.questionsSubmitTapped(messageID: "01")) { $0.answering = ["01"] }
        await store.receive(\.questionsResponse) {
            $0.answering = []
            $0.questionsDrafts = [:]
        }
        await store.receive(\.resync) { $0.isLoading = true }
        await store.receive(\.pageResponse.success) {
            $0.isLoading = false
            $0.messages[id: "01"] = timedOut
        }
        #expect(store.state.alert == nil)
        #expect(store.state.questionsErrors["01"] == nil)
    }

    @Test func aRefusedQuestionsAnswerShowsInlineAndKeepsTheDraft() async throws {
        let draft = LeoChatQuestionsDraft(questions: Self.questions)
            .choosing("Swift", question: "q1").choosing("A", question: "q2")
        let store = Self.questionsStore(try Self.questionsCard(), drafts: ["01": draft], answerQuestions: { _, _ in
            throw LeoChatAnswerError.invalid("invalid: text too long")
        })

        await store.send(.questionsSubmitTapped(messageID: "01")) { $0.answering = ["01"] }
        await store.receive(\.questionsResponse) {
            $0.answering = []
            $0.questionsErrors["01"] = "invalid: text too long"
        }
        #expect(store.state.alert == nil)
        #expect(store.state.questionsDrafts["01"] == draft)
        // The next attempt clears the stale error while it is in flight.
        await store.send(.questionsSubmitTapped(messageID: "01")) {
            $0.answering = ["01"]
            $0.questionsErrors["01"] = nil
        }
        await store.receive(\.questionsResponse) {
            $0.answering = []
            $0.questionsErrors["01"] = "invalid: text too long"
        }
    }

    @Test func dismissPostsDismissAndMergesTheExpiredCard() async throws {
        let expired = try Self.questionsCard(state: "expired", closedReason: "dismissed")
        let dismissed = LockIsolated<[String]>([])
        let draft = LeoChatQuestionsDraft(questions: Self.questions).choosing("Swift", question: "q1")
        let store = Self.questionsStore(try Self.questionsCard(), drafts: ["01": draft], dismiss: { id in
            dismissed.withValue { $0.append(id) }
            return expired
        })

        await store.send(.questionsDismissTapped(messageID: "01")) { $0.answering = ["01"] }
        await store.receive(\.questionsResponse) {
            $0.answering = []
            $0.questionsDrafts = [:]
            $0.messages[id: "01"] = expired
        }
        #expect(dismissed.value == ["01"])
        #expect(store.state.messages[id: "01"]?.questionsCard == .inTerminal)
    }

    @Test func aClosedQuestionsCardTakesNoInput() async throws {
        let store = Self.questionsStore(try Self.questionsCard(state: "expired", closedReason: "timeout"))
        await store.send(.questionChoiceTapped(messageID: "01", questionID: "q1", value: "Swift"))
        await store.send(.questionsSubmitTapped(messageID: "01"))
        await store.send(.questionsDismissTapped(messageID: "01"))
    }

    @Test func aSettledUpdateClearsTheQuestionsDraftAndError() async throws {
        let card = try Self.questionsCard()
        var state = ChatThreadTests.state()
        state.messages = [card]
        state.questionsDrafts["01"] = LeoChatQuestionsDraft(questions: Self.questions).choosing("Swift", question: "q1")
        state.questionsErrors["01"] = "boom"
        let store = TestStore(initialState: state) { ChatThread() }
        let timedOut = try Self.questionsCard(state: "expired", closedReason: "timeout")

        await store.send(.chatEvent(.updated(timedOut))) {
            $0.questionsDrafts = [:]
            $0.questionsErrors = [:]
            $0.messages[id: "01"] = timedOut
        }
    }
}
