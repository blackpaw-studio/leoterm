import Foundation
import LeoKit

/// One request against a chat prompt, shared by the chat pane and the
/// inbox so an answer reaches the agent the same way from either: the
/// daemon's copy (or none), a prompt that settled meanwhile (409), or a
/// refusal with the daemon's reason. Drafts and what to show stay with
/// each caller.
enum LeoChatAnswering {
    enum Outcome: Equatable {
        /// The request landed; the daemon's copy of the prompt, if it sent one.
        case answered(LeoChatMessage?)
        /// The prompt was already answered, expired or withdrawn.
        case settled
        /// Refused or failed; `localizedDescription` of the error.
        case failed(String)
    }

    /// Runs `request`, mapping a 409 to `.settled` and any other error to `.failed`.
    static func perform(_ request: () async throws -> LeoChatMessage?) async -> Outcome {
        do {
            return .answered(try await request())
        } catch LeoChatAnswerError.settled {
            return .settled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func answer(_ answer: LeoChatAnswer, messageID: String, agent: String, via client: any LeoChatClient) async -> Outcome {
        await perform { try await client.answer(agent: agent, messageID: messageID, answer: answer) }
    }

    static func answerQuestions(
        _ answers: [String: LeoChatAnswer], messageID: String, agent: String, via client: any LeoChatClient
    ) async -> Outcome {
        await perform { try await client.answerQuestions(agent: agent, messageID: messageID, answers: answers) }
    }

    static func dismiss(messageID: String, agent: String, via client: any LeoChatClient) async -> Outcome {
        await perform { try await client.dismiss(agent: agent, messageID: messageID) }
    }
}
