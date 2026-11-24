import Foundation
import LeoKit

/// What the ask and questions cards need from whoever owns the answer
/// drafts: the chat pane, or the inbox (which keeps drafts of its own).
@MainActor protocol LeoChatAnswerHost: ObservableObject {
    /// Message ids with an answer in flight.
    var answering: Set<String> { get }
    /// A refused questions answer, shown inside its card.
    var questionsErrors: [String: String] { get }

    func askDraft(for messageID: String) -> LeoChatAskDraft
    func askAnswer(for messageID: String) -> LeoChatAnswer?
    func choose(messageID: String, value: String) async
    func setAskText(messageID: String, _ text: String)
    func submitAsk(messageID: String) async

    func questionsDraft(for messageID: String) -> LeoChatQuestionsDraft?
    func chooseQuestion(messageID: String, questionID: String, value: String)
    func setQuestionText(messageID: String, questionID: String, _ text: String)
    func submitQuestions(messageID: String) async
    func dismissQuestions(messageID: String) async
}

extension LeoChatPaneModel: LeoChatAnswerHost {}
extension LeoInboxModel: LeoChatAnswerHost {}
