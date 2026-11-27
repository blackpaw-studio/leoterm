import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The Mac inbox's glue: open asks from the event stream and the daemon,
/// answers through the chat path, and the synced "seen" state.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct LeoInboxModelTests {
    private static let alpha = LeoAgentID(host: .local, name: "alpha")
    private static let box = LeoHostID.remote("box")
    private static let boxBeta = LeoAgentID(host: box, name: "beta")
    private static let now = Date(timeIntervalSince1970: 5000)

    private let client = FakeChatClient()
    private let boxClient = FakeChatClient()
    private let saved = SavedSeen()

    private final class SavedSeen: @unchecked Sendable {
        var state: LeoInboxSeenState?
    }

    private func make() -> LeoInboxModel {
        let model = LeoInboxModel(
            clients: [.local: client], persistence: .init(load: { LeoInboxSeenState() }, save: { [saved] in saved.state = $0 }),
            now: { Self.now }
        )
        model.bind(client, host: .local)
        return model
    }

    private func agent(
        _ id: LeoAgentID = Self.alpha, state: LeoAttentionState = .working, revision: Int = 1, preview: String? = nil, at seconds: Int? = nil,
        bootID: String? = nil
    ) -> LeoInboxAgent {
        LeoInboxAgent(
            id: id, name: id.name, machine: id.host.displayName,
            signal: LeoAttentionSignal(
                state: state, revision: revision, preview: preview, at: seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ),
            bootID: bootID
        )
    }

    private func openAsk(_ id: String = "q", agent: String = "alpha", at seconds: Int = 100) throws -> LeoChatMessage {
        let input = try LeoChatInput(kind: .buttons, options: [LeoChatOption(value: "y", label: "Yes"), LeoChatOption(value: "n", label: "No")])
        return chatMessage(id, agent: agent, kind: .ask, text: "Deploy?", state: "open", at: seconds, input: input)
    }

    // MARK: Open asks

    @Test func aLiveAskAppearsInTheInboxFromOneEvent() throws {
        let model = make()
        model.updateAgents([agent()])
        #expect(model.inbox.blocked.isEmpty)
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.message(try openAsk()))))
        #expect(model.inbox.blocked.map(\.id) == [Self.alpha])
        #expect(model.inbox.badge == .count(1))
    }

    @Test func aSettledEventRemovesTheAsk() throws {
        let model = make()
        model.updateAgents([agent()])
        let ask = try openAsk()
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.message(ask))))
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.updated(ask.answered(LeoChatAnswer(values: ["y"]))))))
        #expect(model.inbox.blocked.isEmpty)
    }

    @Test func seedingBringsInEveryOpenAskTheDaemonHas() async throws {
        await client.setOpenAsks([try openAsk("q1"), try openAsk("q2", agent: "beta", at: 50)])
        let model = make()
        model.updateAgents([agent(), agent(LeoAgentID(host: .local, name: "beta"))])
        await model.seed(host: .local)
        #expect(model.inbox.blocked.map(\.agent) == ["beta", "alpha"])
    }

    @Test func withoutTheOpenAsksRouteSeedingReadsTheThreadsLastMessages() async throws {
        await client.setOpenAsks(nil)
        await client.setThreads([LeoChatThread(agent: "alpha", lastMessage: try openAsk())])
        let model = make()
        model.updateAgents([agent()])
        await model.seed(host: .local)
        #expect(model.inbox.blocked.map(\.id) == [Self.alpha])
    }

    @Test func aSettleThatLandsDuringTheSeedWinsOverTheSeedsOlderAnswer() async throws {
        await client.setOpenAsks([try openAsk()])
        await client.holdOpenAsks()
        let model = make()
        model.updateAgents([agent()])
        let seeding = Task { await model.seed(host: .local) }
        await client.waitForOpenAsksRequests(1)
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.updated(try openAsk().answered(LeoChatAnswer(values: ["y"]))))))
        await client.releaseOpenAsks()
        await seeding.value
        #expect(model.inbox.blocked.isEmpty)
    }

    @Test func aDisconnectedMachineLosesItsAsksUntilItReconnects() async throws {
        let model = make()
        model.bind(boxClient, host: Self.box)
        model.updateAgents([agent(Self.boxBeta)])
        model.receive(LeoChatFeedDelivery(host: Self.box, signal: .event(.message(try openAsk(agent: "beta")))))
        #expect(model.inbox.blocked.count == 1)
        model.unbind(Self.box)
        #expect(model.inbox.blocked.isEmpty)
    }

    @Test func aResyncReseedsThatMachine() async throws {
        await client.setOpenAsks([try openAsk()])
        let model = make()
        model.updateAgents([agent()])
        model.receive(LeoChatFeedDelivery(host: .local, signal: .resync))
        await model.settled()
        #expect(model.inbox.blocked.map(\.id) == [Self.alpha])
    }

    // MARK: Answering

    @Test func answeringSendsThroughTheChatPathAndDropsTheCard() async throws {
        let model = make()
        model.updateAgents([agent()])
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.message(try openAsk()))))
        await model.choose(messageID: "q", value: "y")
        #expect(await client.answers.map(\.answer) == [LeoChatAnswer(values: ["y"])])
        #expect(await client.answers.map(\.agent) == ["alpha"])
        #expect(model.inbox.blocked.isEmpty)
    }

    @Test func aPromptSettledMeanwhileIsDroppedWithoutAnError() async throws {
        await client.setAnswerResult(.failure(LeoChatAnswerError.settled))
        let model = make()
        model.updateAgents([agent()])
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.message(try openAsk()))))
        await model.choose(messageID: "q", value: "y")
        #expect(model.inbox.blocked.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func aRefusedAnswerKeepsTheCardAndSaysWhy() async throws {
        await client.setAnswerResult(.failure(LeoChatAnswerError.invalid("answer does not fit")))
        let model = make()
        model.updateAgents([agent()])
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.message(try openAsk()))))
        await model.choose(messageID: "q", value: "y")
        #expect(model.inbox.blocked.count == 1)
        #expect(model.notice == "Couldn't answer: answer does not fit")
    }

    @Test func aTextAnswerSendsTheDraftTrimmed() async throws {
        let input = try LeoChatInput(kind: .text, options: [])
        let ask = chatMessage("t", kind: .ask, text: "Name?", state: "open", at: 10, input: input)
        let model = make()
        model.updateAgents([agent()])
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.message(ask))))
        model.setAskText(messageID: "t", "  ship it ")
        await model.submitAsk(messageID: "t")
        #expect(await client.answers.map(\.answer) == [LeoChatAnswer(text: "ship it")])
    }

    // MARK: Seen

    @Test func focusingAnAgentsTerminalMarksItsFinishedItemSeen() async {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .finished, revision: 3, preview: "Done", at: 1000)])
        await model.seed(host: .local)
        #expect(model.inbox.finished.map(\.isUnread) == [true])
        model.agentOpened(Self.alpha)
        #expect(model.inbox.finished.map(\.isUnread) == [false])
        await model.settled()
        #expect(await client.markedSeen == [["alpha"]])
    }

    @Test func anAgentSeenEventFromAnotherClientClearsTheItem() async {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .finished, revision: 3, at: 1000)])
        await model.seed(host: .local)
        model.receive(LeoChatFeedDelivery(host: .local, signal: .agentSeen(agent: "alpha", seenAt: Date(timeIntervalSince1970: 2000))))
        #expect(model.inbox.finished.map(\.isUnread) == [false])
    }

    @Test func clearFinishedMarksEveryFinishedItemAndLeavesBlockedOnes() async throws {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([
            agent(state: .finished, at: 1000), agent(LeoAgentID(host: .local, name: "beta"), state: .errored, at: 1100),
            agent(LeoAgentID(host: .local, name: "gamma"), state: .needsInput, at: 900),
        ])
        await model.seed(host: .local)
        model.clearFinished()
        #expect(model.inbox.finished.map(\.isUnread) == [false, false])
        #expect(model.inbox.blocked.count == 1)
        await model.settled()
        #expect(Set(await client.markedSeen.flatMap { $0 }) == ["alpha", "beta"])
    }

    @Test func withoutTheSeenRouteMarksStayLocalAndAreSaved() async {
        await client.setSeen(nil)
        let model = make()
        model.updateAgents([agent(state: .finished, revision: 3, at: 1000)])
        await model.seed(host: .local)
        model.agentOpened(Self.alpha)
        #expect(model.inbox.finished.map(\.isUnread) == [false])
        #expect(saved.state != nil)
        await model.settled()
        #expect(await client.markedSeen.isEmpty)
    }

    @Test func selectingAFinishedItemMarksItSeenButSelectingABlockedOneDoesNot() async throws {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .finished, at: 1000), agent(LeoAgentID(host: .local, name: "beta"), state: .needsInput, at: 900)])
        await model.seed(host: .local)
        model.select(LeoAgentID(host: .local, name: "beta"))
        #expect(model.inbox.blocked.count == 1)
        #expect(model.inbox.finished.first?.isUnread == true)
        model.select(Self.alpha)
        #expect(model.inbox.finished.first?.isUnread == false)
    }

    @Test func aDaemonRestartReflagsAFinishedItemSeenUnderTheOldBootOnADaemonWithoutTheSeenRoute() async {
        await client.setSeen(nil)
        let model = make()
        model.updateAgents([agent(state: .finished, revision: 3, at: 1000, bootID: "boot-a")])
        await model.seed(host: .local)
        model.agentOpened(Self.alpha)
        #expect(model.inbox.finished.map(\.isUnread) == [false])
        // Revisions restart with the daemon: the same number is a new event.
        model.updateAgents([agent(state: .finished, revision: 3, at: 1000, bootID: "boot-b")])
        #expect(model.inbox.finished.map(\.isUnread) == [true])
    }

    private func transition(_ to: LeoAttentionState, revision: Int, notifies: Bool) -> LeoAttentionTransition {
        LeoAttentionTransition(id: Self.alpha, from: .working, to: to, revision: revision, shouldNotify: notifies)
    }

    @Test(arguments: [LeoAttentionState.finished, .errored])
    func aTurnThatEndsOnTheFocusedAgentIsNeverUnread(state: LeoAttentionState) async {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: state, revision: 2, at: 1000)])
        await model.seed(host: .local)
        #expect(model.inbox.finished.map(\.isUnread) == [true])
        model.transitionsCommitted([transition(state, revision: 2, notifies: false)])
        #expect(model.inbox.finished.map(\.isUnread) == [false])
    }

    @Test func theTransitionMayBeCommittedBeforeTheSidebarRowCarriesItsSignal() async {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .working, revision: 1, at: 900)])
        await model.seed(host: .local)
        model.transitionsCommitted([transition(.finished, revision: 2, notifies: false)])
        model.updateAgents([agent(state: .finished, revision: 2, at: 1000)])
        #expect(model.inbox.finished.map(\.isUnread) == [false])
    }

    @Test func aTurnThatEndsOnAnAgentNobodyWatchesStaysUnread() async {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .finished, revision: 2, at: 1000)])
        await model.seed(host: .local)
        model.transitionsCommitted([transition(.finished, revision: 2, notifies: true)])
        #expect(model.inbox.finished.map(\.isUnread) == [true])
    }

    @Test func aWatchedTurnDoesNotHideALaterOne() async {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .finished, revision: 2, at: 1000)])
        await model.seed(host: .local)
        model.transitionsCommitted([transition(.finished, revision: 2, notifies: false)])
        // After the (fixed-clock) seen mark at 5000.
        model.updateAgents([agent(state: .finished, revision: 4, at: 6000)])
        #expect(model.inbox.finished.map(\.isUnread) == [true])
    }

    // MARK: Dismiss

    @Test func dismissingABlockedItemSendsOnlyASeenMark() async throws {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .needsInput, at: 900)])
        await model.seed(host: .local)
        let item = try #require(model.inbox.blocked.first)

        model.dismiss(item)

        #expect(model.inbox.blocked.isEmpty)
        #expect(model.inbox.badge == .none)
        await model.settled()
        #expect(await client.markedSeen == [["alpha"]])
        #expect(await client.answers.isEmpty)
        #expect(await client.dismissals.isEmpty)
    }

    @Test func aDismissedItemReturnsWhenItChanges() async throws {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .needsInput, revision: 1, at: 900)])
        await model.seed(host: .local)
        model.dismiss(try #require(model.inbox.blocked.first))
        #expect(model.inbox.blocked.isEmpty)

        model.updateAgents([agent(state: .needsInput, revision: 3, at: 9000)])

        #expect(model.inbox.blocked.count == 1)
    }

    @Test func openingABlockedAgentKeepsItInTheInbox() async throws {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .working)])
        await model.seed(host: .local)
        model.receive(LeoChatFeedDelivery(host: .local, signal: .event(.message(try openAsk()))))

        model.agentOpened(Self.alpha)

        #expect(model.inbox.blocked.count == 1)
        await model.settled()
        #expect(await client.markedSeen.isEmpty)
    }

    @Test func openingAnAgentBeforeItLoadsSendsNoSeenMark() async {
        await client.setSeen([:])
        let model = make()
        await model.seed(host: .local)

        // The sidebar has not delivered the agent yet: it may be blocked.
        model.agentOpened(Self.alpha)
        model.updateAgents([agent(state: .finished, revision: 3, at: 1000)])

        #expect(model.inbox.finished.map(\.isUnread) == [true])
        await model.settled()
        #expect(await client.markedSeen.isEmpty)
    }

    @Test func dismissingTheLastBlockedItemLeavesAFinishedOneUnread() async throws {
        await client.setSeen([:])
        let model = make()
        model.updateAgents([agent(state: .needsInput, at: 900), agent(LeoAgentID(host: .local, name: "beta"), state: .finished, at: 1000)])
        await model.seed(host: .local)
        model.select(Self.alpha)

        model.dismiss(try #require(model.inbox.blocked.first))

        #expect(model.inbox.finished.map(\.isUnread) == [true])
        await model.settled()
        #expect(await client.markedSeen == [["alpha"]])
    }
}
