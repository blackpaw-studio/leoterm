import Combine
import Foundation
import LeoKit

/// The Needs-you inbox on the Mac: open `leo_chat_ask` rows from every
/// connected machine (seeded from the daemon, kept current by chat events),
/// the per-agent "seen" state shared with the daemon (or kept locally for an
/// older one), and answers sent through the same path as the chat pane
/// (`LeoChatAnswering`) with drafts of its own. What is shown is always
/// `LeoInbox.derive` over those inputs and the sidebar's agents; nothing is
/// authored here.
@MainActor final class LeoInboxModel: ObservableObject {
    enum Filter: CaseIterable {
        case all, needsYou, finished
    }

    @Published private(set) var inbox = LeoInbox.empty
    @Published var filter = Filter.all
    /// The row picked in the list (nil: the first one shown).
    @Published private(set) var selection: LeoAgentID?
    /// Message ids with an answer in flight.
    @Published private(set) var answering: Set<String> = []
    @Published private(set) var askDrafts: [String: LeoChatAskDraft] = [:]
    @Published private(set) var questionsDrafts: [String: LeoChatQuestionsDraft] = [:]
    /// A refused questions answer, shown inside its card.
    @Published private(set) var questionsErrors: [String: String] = [:]
    /// A refused or failed answer.
    @Published private(set) var notice: String?

    private var clients: [LeoHostID: any LeoChatClient]
    private let persistence: LeoInboxSeenPersistence
    private let now: () -> Date
    private var agents: [LeoInboxAgent] = []
    private var openAsks = LeoOpenAsks()
    private var seen: LeoInboxSeenState
    private var seedTasks: [LeoHostID: Task<Void, Never>] = [:]
    /// Identifies each machine's seed whose answer still counts; never reset.
    private var seedTokens: [LeoHostID: Int] = [:]
    /// Chat events that arrived while a machine's seed was in flight: its
    /// answer may predate them, so they are applied again when it lands.
    private var eventsDuringSeed: [LeoHostID: [LeoChatEvent]] = [:]
    private var seenTasks: [UUID: Task<Void, Never>] = [:]
    /// DEBUG fixture: the agents and asks are fixed, never overwritten by the sidebar.
    private(set) var isFixture = false

    init(
        clients: [LeoHostID: any LeoChatClient] = [:], persistence: LeoInboxSeenPersistence = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.clients = clients
        self.persistence = persistence
        self.now = now
        seen = persistence.load()
    }

    // MARK: Machines

    /// `host`'s daemon connected. Nothing loads here: the machine's next
    /// resync (hello) seeds it.
    func bind(_ client: any LeoChatClient, host: LeoHostID) {
        invalidateSeed(host)
        clients[host] = client
    }

    /// `host`'s connection dropped: its asks drop out of the inbox, and
    /// come back with the next seed.
    func unbind(_ host: LeoHostID) {
        invalidateSeed(host)
        clients[host] = nil
        openAsks.disconnect(host: host)
        rederive()
    }

    /// The sidebar's agents changed (rows, attention signals, connectivity).
    func updateAgents(_ updated: [LeoInboxAgent]) {
        guard !isFixture, updated != agents else { return }
        agents = updated
        rederive()
    }

    #if DEBUG
    /// Shows exactly `agents`, their open asks (with the agent's message
    /// before each, as context) and `seen` (`LEO_INBOX_FIXTURE`).
    func installFixture(agents: [LeoInboxAgent], messages: [LeoChatMessage], seen: LeoInboxSeenState) {
        isFixture = true
        self.agents = agents
        self.seen = seen
        openAsks.seed(host: .local, messages: messages, complete: true)
        for host in Set(agents.map(\.id.host)) where host != .local { openAsks.seed(host: host, messages: messages, complete: true) }
        rederive()
    }
    #endif

    // MARK: Feed

    func receive(_ delivery: LeoChatFeedDelivery) {
        let host = delivery.host
        guard clients[host] != nil else { return }
        switch delivery.signal {
        case .event(let event):
            if eventsDuringSeed[host] != nil { eventsDuringSeed[host]?.append(event) }
            openAsks.apply(host: host, event: event)
            rederive()
        case .resync:
            startSeed(host)
        case .agentSeen(let agent, let seenAt):
            seen.apply(host: host, agent: agent, seenAt: seenAt)
            persistence.save(seen)
            rederive()
        }
    }

    /// Returns once the seeds and seen updates in flight have landed or been dropped.
    func settled() async {
        for task in Array(seedTasks.values) { await task.value }
        for task in Array(seenTasks.values) { await task.value }
    }

    private func startSeed(_ host: LeoHostID) {
        guard clients[host] != nil else { return }
        seedTasks[host] = Task { [weak self] in await self?.seed(host: host) }
    }

    /// Loads `host`'s open asks (the daemon's route, else the threads' last
    /// messages) and its shared seen map. A failed request keeps what is shown.
    func seed(host: LeoHostID) async {
        guard let client = clients[host] else { return }
        invalidateSeed(host, keepTask: true)
        let token = seedTokens[host, default: 0]
        eventsDuringSeed[host] = []
        let asks = await Self.fetchAsks(client)
        let seenResult = await Self.fetchSeen(client)
        guard token == seedTokens[host] else { return }
        let buffered = eventsDuringSeed.removeValue(forKey: host) ?? []
        if let asks { openAsks.seed(host: host, messages: asks.messages, complete: asks.isComplete) }
        buffered.forEach { openAsks.apply(host: host, event: $0) }
        if let seenResult {
            seen.seed(host: host, seen: seenResult)
            persistence.save(seen)
        }
        rederive()
    }

    private static func fetchAsks(_ client: any LeoChatClient) async -> (messages: [LeoChatMessage], isComplete: Bool)? {
        do {
            if let open = try await client.openAsks() { return (open, true) }
            return (try await client.threads().compactMap(\.lastMessage), false)
        } catch {
            return nil
        }
    }

    /// The map (nil inside: no route, so local marks); nil outside when the request failed.
    private static func fetchSeen(_ client: any LeoChatClient) async -> [String: Date]?? {
        do {
            return .some(try await client.seen())
        } catch {
            return nil
        }
    }

    private func invalidateSeed(_ host: LeoHostID, keepTask: Bool = false) {
        if !keepTask {
            seedTasks[host]?.cancel()
            seedTasks[host] = nil
        }
        seedTokens[host, default: 0] += 1
        eventsDuringSeed[host] = nil
    }

    // MARK: Seen

    /// The user opened `agent` (its chat, its terminal, or its inbox detail).
    func agentOpened(_ agent: LeoAgentID) {
        markSeen([agent])
    }

    /// Picks a row; looking at a finished one marks it seen.
    func select(_ agent: LeoAgentID?) {
        selection = agent
        guard let agent, let item = (inbox.blocked + inbox.finished).first(where: { $0.id == agent }), !item.isBlocked else { return }
        markSeen([agent])
    }

    /// "Clear Finished": every unread finished item shown.
    func clearFinished() {
        clear(inbox.finished.filter(\.isUnread))
    }

    func clear(_ items: [LeoInboxItem]) {
        let finished = items.filter { !$0.isBlocked }
        guard !finished.isEmpty else { return }
        seen.clear(finished, now: now())
        afterSeenChange(sending: finished.map(\.id))
    }

    private func markSeen(_ ids: [LeoAgentID]) {
        let known = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            let agent = known[id]
            seen.markSeen(id, at: agent?.signal?.at, revision: agent?.signal?.revision, bootID: agent?.bootID, now: now())
        }
        afterSeenChange(sending: ids)
    }

    private func afterSeenChange(sending ids: [LeoAgentID]) {
        persistence.save(seen)
        rederive()
        for (host, group) in Dictionary(grouping: ids, by: \.host) { sendSeen(group.map(\.name), host: host) }
    }

    /// Tells a synced host's daemon (so other clients clear too) and adopts
    /// the times it answers with. A local-mode host has no route.
    private func sendSeen(_ names: [String], host: LeoHostID) {
        guard case .synced = seen.hosts[host], let client = clients[host] else { return }
        let id = UUID()
        seenTasks[id] = Task { [weak self] in
            let times = try? await client.markSeen(agents: names)
            guard let self else { return }
            seenTasks[id] = nil
            guard let times, !times.isEmpty else { return }
            times.forEach { seen.apply(host: host, agent: $0.key, seenAt: $0.value) }
            persistence.save(seen)
            rederive()
        }
    }

    // MARK: Derived

    private func rederive() {
        let derived = LeoInbox.derive(agents: agents, openAsks: openAsks.threads, seen: seen)
        if derived != inbox { inbox = derived }
        dropSettledDrafts()
    }

    /// What the list shows under the filter.
    var shownBlocked: [LeoInboxItem] { filter == .finished ? [] : inbox.blocked }
    /// The finished items "since you looked": the unread ones, plus the one
    /// shown in the detail so it doesn't vanish the moment it is read.
    var shownFinished: [LeoInboxItem] {
        filter == .needsYou ? [] : inbox.finished.filter { $0.isUnread || $0.id == selection }
    }

    /// The item the detail shows: the picked row, else the first one shown.
    var selectedItem: LeoInboxItem? {
        let shown = shownBlocked + shownFinished
        return shown.first { $0.id == selection } ?? shown.first
    }

    // MARK: Answers

    /// The open chat ask or permission row behind `messageID`, with its agent.
    private func openMessage(_ messageID: String) -> (agent: LeoAgentID, message: LeoChatMessage)? {
        for item in inbox.blocked {
            if case .chatAsk(let message) = item.kind, message.id == messageID, message.isOpen { return (item.id, message) }
        }
        return nil
    }

    private func openInput(_ messageID: String) -> LeoChatInput? {
        guard let open = openMessage(messageID), !answering.contains(messageID) else { return nil }
        return open.message.answerInput
    }

    func askDraft(for messageID: String) -> LeoChatAskDraft { askDrafts[messageID] ?? LeoChatAskDraft() }

    /// The answer Submit would send, or nil while the daemon would refuse it.
    func askAnswer(for messageID: String) -> LeoChatAnswer? {
        guard let input = openInput(messageID) else { return nil }
        return askDraft(for: messageID).answer(for: input)
    }

    /// A choice clicked: `buttons` (and permission prompts) answer at once,
    /// `radio` and `checkboxes` update the draft.
    func choose(messageID: String, value: String) async {
        guard let input = openInput(messageID) else { return }
        let draft = askDraft(for: messageID).choosing(value, in: input)
        guard input.kind == .buttons else {
            askDrafts[messageID] = draft
            return
        }
        guard let answer = draft.answer(for: input) else { return }
        await self.answer(messageID: messageID, answer)
    }

    func setAskText(messageID: String, _ text: String) {
        guard openInput(messageID) != nil, askDraft(for: messageID).text != text else { return }
        askDrafts[messageID] = askDraft(for: messageID).withText(text)
    }

    func submitAsk(messageID: String) async {
        guard let answer = askAnswer(for: messageID) else { return }
        await self.answer(messageID: messageID, answer)
    }

    /// Sends `answer`. A prompt that settled meanwhile (409) just leaves the
    /// inbox; any other refusal says why and keeps the draft.
    func answer(messageID: String, _ answer: LeoChatAnswer) async {
        await settle(messageID, answered: { $0.answered(answer) }, failure: nil, request: { client, agent in
            await LeoChatAnswering.answer(answer, messageID: messageID, agent: agent, via: client)
        })
    }

    // MARK: Questions card

    func questionsDraft(for messageID: String) -> LeoChatQuestionsDraft? {
        guard let questions = openQuestions(messageID) else { return nil }
        return questionsDrafts[messageID] ?? LeoChatQuestionsDraft(questions: questions)
    }

    func chooseQuestion(messageID: String, questionID: String, value: String) {
        updateQuestionsDraft(messageID) { $0.choosing(value, question: questionID) }
    }

    func setQuestionText(messageID: String, questionID: String, _ text: String) {
        updateQuestionsDraft(messageID) { $0.withText(text, question: questionID) }
    }

    func submitQuestions(messageID: String) async {
        guard let draft = questionsDraft(for: messageID), draft.isComplete else { return }
        let payload = draft.answersPayload
        await settle(messageID, answered: { $0.answered(LeoChatAnswer(answers: payload)) }, failure: "Couldn't answer", request: { client, agent in
            await LeoChatAnswering.answerQuestions(payload, messageID: messageID, agent: agent, via: client)
        })
    }

    /// "Answer in terminal": the daemon hands the question to the agent's
    /// own terminal dialog and expires the card.
    func dismissQuestions(messageID: String) async {
        guard openQuestions(messageID) != nil else { return }
        await settle(messageID, answered: { $0.answered(LeoChatAnswer(values: [], text: nil)) }, failure: "Couldn't hand the question to the terminal", request: { client, agent in
            await LeoChatAnswering.dismiss(messageID: messageID, agent: agent, via: client)
        })
    }

    /// One request against an open prompt. The daemon's copy (or `answered`'s
    /// local one) replaces it, so it leaves the inbox at once; a 409 drops it
    /// the same way (the daemon's own update follows). A questions card shows
    /// a refusal inside itself (`failure`), anything else as the notice.
    private func settle(
        _ messageID: String, answered: (LeoChatMessage) -> LeoChatMessage, failure: String?,
        request: (any LeoChatClient, String) async -> LeoChatAnswering.Outcome
    ) async {
        guard let open = openMessage(messageID), let client = clients[open.agent.host], answering.insert(messageID).inserted else { return }
        questionsErrors[messageID] = nil
        notice = nil
        defer { answering.remove(messageID) }
        switch await request(client, open.agent.name) {
        case .answered(let updated):
            apply(updated ?? answered(open.message), host: open.agent.host)
        case .settled:
            questionsDrafts[messageID] = nil
            askDrafts[messageID] = nil
            apply(answered(open.message), host: open.agent.host)
        case .failed(let reason):
            if let failure { questionsErrors[messageID] = "\(failure): \(reason)" } else { notice = "Couldn't answer: \(reason)" }
        }
    }

    private func apply(_ message: LeoChatMessage, host: LeoHostID) {
        openAsks.apply(host: host, event: .updated(message))
        rederive()
    }

    func dismissNotice() { notice = nil }

    private func updateQuestionsDraft(_ messageID: String, _ change: (LeoChatQuestionsDraft) -> LeoChatQuestionsDraft) {
        guard !answering.contains(messageID), let draft = questionsDraft(for: messageID) else { return }
        let updated = change(draft)
        guard updated != draft else { return }
        questionsDrafts[messageID] = updated
        questionsErrors[messageID] = nil
    }

    private func openQuestions(_ messageID: String) -> [LeoChatQuestion]? {
        guard let message = openMessage(messageID)?.message, let input = message.input, input.kind == .questions else { return nil }
        return input.questions
    }

    /// A prompt that left the inbox loses its drafts.
    private func dropSettledDrafts() {
        guard !askDrafts.isEmpty || !questionsDrafts.isEmpty || !questionsErrors.isEmpty else { return }
        let open = Set(inbox.blocked.compactMap { item -> String? in
            if case .chatAsk(let message) = item.kind { message.id } else { nil }
        })
        askDrafts.keys.filter { !open.contains($0) }.forEach { askDrafts[$0] = nil }
        questionsDrafts.keys.filter { !open.contains($0) }.forEach { questionsDrafts[$0] = nil }
        questionsErrors.keys.filter { !open.contains($0) }.forEach { questionsErrors[$0] = nil }
    }
}
