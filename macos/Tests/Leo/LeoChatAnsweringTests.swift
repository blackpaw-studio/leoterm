import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The answer path the chat pane and the inbox share: one request against a
/// prompt, reported as answered, already settled (409) or refused.
@Suite(.timeLimit(.minutes(1)))
struct LeoChatAnsweringTests {
    private let client = FakeChatClient()

    @Test func anAnswerGoesToTheAgentsPromptAndReturnsTheDaemonsCopy() async {
        let settled = chatMessage("q", kind: .ask, state: "answered", at: 1)
        await client.setAnswerResult(.success(settled))
        let outcome = await LeoChatAnswering.answer(LeoChatAnswer(values: ["y"]), messageID: "q", agent: "alpha", via: client)
        #expect(outcome == .answered(settled))
        #expect(await client.answers.map(\.id) == ["q"])
        #expect(await client.answers.map(\.answer) == [LeoChatAnswer(values: ["y"])])
    }

    @Test func anAnswerWithoutACopyIsStillAnswered() async {
        let outcome = await LeoChatAnswering.answer(LeoChatAnswer(values: ["y"]), messageID: "q", agent: "alpha", via: client)
        #expect(outcome == .answered(nil))
    }

    @Test func aPromptSettledMeanwhileIsReportedAsSettledNotAsAFailure() async {
        await client.setAnswerResult(.failure(LeoChatAnswerError.settled))
        let outcome = await LeoChatAnswering.answer(LeoChatAnswer(values: ["y"]), messageID: "q", agent: "alpha", via: client)
        #expect(outcome == .settled)
    }

    @Test func aRefusedAnswerCarriesTheDaemonsReason() async {
        await client.setAnswerResult(.failure(LeoChatAnswerError.invalid("answer does not fit")))
        let outcome = await LeoChatAnswering.answer(LeoChatAnswer(values: ["y"]), messageID: "q", agent: "alpha", via: client)
        #expect(outcome == .failed("answer does not fit"))
    }

    @Test func aQuestionsAnswerSendsOneAnswerPerQuestion() async {
        let payload = ["one": LeoChatAnswer(values: ["a"])]
        let outcome = await LeoChatAnswering.answerQuestions(payload, messageID: "q", agent: "alpha", via: client)
        #expect(outcome == .answered(nil))
        #expect(await client.questionAnswers.map(\.answers) == [payload])
    }

    @Test func dismissingHandsTheCardBackToTheTerminal() async {
        await client.setDismissResult(.failure(LeoChatAnswerError.settled))
        let outcome = await LeoChatAnswering.dismiss(messageID: "q", agent: "alpha", via: client)
        #expect(outcome == .settled)
        #expect(await client.dismissals.map(\.id) == ["q"])
    }
}
