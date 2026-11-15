import ComposableArchitecture
import Foundation
import LeoKit

/// The requests the reducer runs: answering and settling prompts, paging, read marks.
extension ChatThread {
    func submit(_ answer: LeoChatAnswer, to id: String, state: inout State) -> Effect<Action> {
        state.answering.insert(id)
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] send in
            await send(.answerResponse(messageID: id, answer, Result {
                try await chatClient.answer(try secrets.connection(for: daemon), agent, id, answer)
            }))
        }
    }

    /// Runs one request that settles a questions card (answer or dismiss),
    /// disabling the card and clearing its stale error until it returns.
    func settleQuestions(
        _ id: String, state: inout State,
        _ request: @escaping @Sendable (ChatClient, DaemonConnection, String) async throws -> LeoChatMessage?
    ) -> Effect<Action> {
        state.answering.insert(id)
        state.questionsErrors[id] = nil
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] send in
            await send(.questionsResponse(messageID: id, Result {
                try await request(chatClient, try secrets.connection(for: daemon), agent)
            }))
        }
    }

    /// Resyncs after a 409. The newest page may not reach back to the
    /// prompt, so one older than the newest loaded message first fetches
    /// the page just above it, which carries its settled copy.
    func refreshSettled(_ id: String, state: State) -> Effect<Action> {
        guard let index = state.messages.index(id: id), index + 1 < state.messages.count else { return .send(.resync) }
        let query = LeoChatPageQuery(before: state.messages[index + 1].id, limit: 1, task: state.taskFilter)
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] send in
            await send(.settledMessageResponse(messageID: id, Result {
                try await chatClient.messages(try secrets.connection(for: daemon), agent, query)
            }))
            await send(.resync)
        }
    }

    func loadNewest(state: inout State) -> Effect<Action> {
        state.isLoading = true
        state.isLoadingOlder = false
        state.liveSinceFetch = []
        return fetch(LeoChatPageQuery(limit: Self.pageSize, task: state.taskFilter), state: state) { .pageResponse($0) }
    }

    func fetch(
        _ query: LeoChatPageQuery, state: State,
        _ action: @escaping @Sendable (Result<LeoChatPage, any Error>) -> Action
    ) -> Effect<Action> {
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] send in
            await send(action(Result {
                try await chatClient.messages(try secrets.connection(for: daemon), agent, query)
            }))
        }
        .cancellable(id: CancelID.page, cancelInFlight: true)
    }

    /// Read marks are best effort: a failure only leaves the unread count up.
    func markRead(_ id: String, state: State) -> Effect<Action> {
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] _ in
            try? await chatClient.markRead(try secrets.connection(for: daemon), agent, id)
        }
    }
}
