import Combine
import Foundation
import LeoKit

/// Unread agent messages per agent on the selected host, for the sidebar
/// rows and the Chat switch. The daemon's read mark is the truth: every
/// resync (hello, gap, snapshot) re-seeds from `threads()`, live agent
/// messages add to it, and a successful read clears an agent. Fed by
/// `LeoRuntime`'s chat relay, upstream of the chat pane's agent guard, so
/// agents that aren't on screen count too.
@MainActor final class LeoChatUnreadStore: ObservableObject {
    @Published private(set) var counts = LeoChatUnreadCounts()
    /// The kind of each agent's latest agent-sent message: seeded from the
    /// threads' `lastMessage`, then kept current by live messages.
    private var latestKinds: [LeoAgentID: LeoChatMessage.Kind] = [:]
    /// Kinds that arrived live since the latest seed began: the seed's
    /// answer may predate them, so they win when it lands.
    private var liveKindsSinceSeedBegan: [LeoAgentID: LeoChatMessage.Kind] = [:]

    private var client: any LeoChatClient
    private var host: LeoHostID
    private var seedTask: Task<Void, Never>?
    /// Identifies the seed whose answer still counts.
    private var seedToken = 0
    /// Agents read since the latest seed began: its answer may predate the
    /// read, so they stay at 0 when it lands.
    private var readSinceSeedBegan: Set<LeoAgentID> = []

    init(client: any LeoChatClient, host: LeoHostID) {
        self.client = client
        self.host = host
    }

    /// The selected connection's daemon changed. Signals from any other
    /// host are ignored from now on, and a seed still in flight is dropped.
    func updateClient(_ client: any LeoChatClient, host: LeoHostID) {
        self.client = client
        self.host = host
        seedTask?.cancel()
        seedTask = nil
        seedToken += 1
    }

    /// A store no daemon feeds, for views built without a runtime (tests).
    static func detached() -> LeoChatUnreadStore {
        LeoChatUnreadStore(
            client: LeoChatPaneModel.makeClient(socketPath: "/dev/null", transport: LeoUnixSocketTransport()), host: .local
        )
    }

    func count(for agent: LeoAgentID) -> Int { counts[agent] }

    func latestAgentKind(for agent: LeoAgentID) -> LeoChatMessage.Kind? { latestKinds[agent] }

    func clear(_ agent: LeoAgentID) {
        readSinceSeedBegan.insert(agent)
        guard counts[agent] > 0 else { return }
        counts = counts.clearing(agent)
    }

    /// `isOnScreen` says whether an agent's chat is being read right now.
    func receive(_ delivery: LeoChatFeedDelivery, isOnScreen: (LeoAgentID) -> Bool) {
        guard delivery.host == host else { return }
        switch delivery.signal {
        case .event(let event):
            let agent = LeoAgentID(host: host, name: event.message.agent)
            if case .message(let message) = event, message.isFromAgent {
                latestKinds[agent] = message.kind
                liveKindsSinceSeedBegan[agent] = message.kind
            }
            counts = counts.receiving(event, host: host, isOnScreen: isOnScreen(agent))
        case .resync:
            seed()
        }
    }

    /// Returns once the seed in flight (if any) has landed or been dropped.
    func settled() async { await seedTask?.value }

    /// Its own task, so a slow `threads()` never stalls the ordered relay.
    /// A failed fetch keeps the counts as they are.
    private func seed() {
        seedTask?.cancel()
        seedToken += 1
        readSinceSeedBegan = []
        liveKindsSinceSeedBegan = [:]
        let (token, client, host) = (seedToken, client, host)
        seedTask = Task { [weak self] in
            guard let threads = try? await client.threads() else { return }
            guard let self, token == self.seedToken else { return }
            let unreadAfterReads = threads.map { thread in
                var thread = thread
                if readSinceSeedBegan.contains(LeoAgentID(host: host, name: thread.agent)) { thread.unread = 0 }
                return thread
            }
            latestKinds = seededKinds(from: threads, host: host)
            counts = counts.seeding(unreadAfterReads, host: host)
        }
    }

    /// The latest agent kinds after a seed: a live kind since the seed began
    /// wins; else the thread's last message if the agent sent it; else the
    /// kind already known (the last message was yours, which says nothing
    /// about the agent's latest).
    private func seededKinds(from threads: [LeoChatThread], host: LeoHostID) -> [LeoAgentID: LeoChatMessage.Kind] {
        let fromThreads = threads.compactMap { thread -> (LeoAgentID, LeoChatMessage.Kind)? in
            guard let last = thread.lastMessage, last.isFromAgent else { return nil }
            return (LeoAgentID(host: host, name: thread.agent), last.kind)
        }
        return latestKinds
            .merging(fromThreads, uniquingKeysWith: { _, seeded in seeded })
            .merging(liveKindsSinceSeedBegan, uniquingKeysWith: { _, live in live })
    }
}
