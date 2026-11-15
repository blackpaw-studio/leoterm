import Combine
import Foundation
import LeoKit

/// Unread agent messages per agent on every connected machine, for the
/// sidebar rows and the Chat switch. Each machine's daemon read mark is the
/// truth: every resync (hello, gap, snapshot) re-seeds that machine from its
/// own `threads()`, live agent messages add to it, and a successful read
/// clears an agent. Fed by `LeoRuntime`'s chat relay, upstream of the chat
/// pane's agent guard, so agents that aren't on screen count too. A machine
/// counts only while bound: the runtime binds it when its daemon connects and
/// unbinds it when the connection drops, which also drops its counts.
@MainActor final class LeoChatUnreadStore: ObservableObject {
    @Published private(set) var counts = LeoChatUnreadCounts()
    /// The kind of each agent's latest agent-sent message: seeded from the
    /// threads' `lastMessage`, then kept current by live messages.
    private var latestKinds: [LeoAgentID: LeoChatMessage.Kind] = [:]
    /// Kinds that arrived live since their machine's latest seed began: the
    /// seed's answer may predate them, so they win when it lands.
    private var liveKindsSinceSeedBegan: [LeoAgentID: LeoChatMessage.Kind] = [:]

    private var clients: [LeoHostID: any LeoChatClient] = [:]
    private var seedTasks: [LeoHostID: Task<Void, Never>] = [:]
    /// Identifies each machine's seed whose answer still counts. Never reset,
    /// so a seed from before an unbind can't count after a rebind.
    private var seedTokens: [LeoHostID: Int] = [:]
    /// Agents read since their machine's latest seed began: its answer may
    /// predate the read, so they stay at 0 when it lands.
    private var readSinceSeedBegan: Set<LeoAgentID> = []

    /// Starts counting `host` from its daemon's client. It does not seed:
    /// the machine's next resync does. A seed still in flight for the host's
    /// previous client is dropped.
    func bind(_ client: any LeoChatClient, host: LeoHostID) {
        invalidateSeed(host)
        clients[host] = client
    }

    /// Stops counting `host`: its signals are ignored from now on, a seed in
    /// flight is dropped, and its counts and kinds go away.
    func unbind(_ host: LeoHostID) {
        invalidateSeed(host)
        clients[host] = nil
        counts = counts.seeding([], host: host)
        latestKinds = latestKinds.filter { $0.key.host != host }
    }

    func isBound(_ host: LeoHostID) -> Bool { clients[host] != nil }

    func count(for agent: LeoAgentID) -> Int { counts[agent] }

    func latestAgentKind(for agent: LeoAgentID) -> LeoChatMessage.Kind? { latestKinds[agent] }

    func clear(_ agent: LeoAgentID) {
        readSinceSeedBegan.insert(agent)
        guard counts[agent] > 0 else { return }
        counts = counts.clearing(agent)
    }

    /// `isOnScreen` says whether an agent's chat is being read right now.
    func receive(_ delivery: LeoChatFeedDelivery, isOnScreen: (LeoAgentID) -> Bool) {
        let host = delivery.host
        guard clients[host] != nil else { return }
        switch delivery.signal {
        case .event(let event):
            let agent = LeoAgentID(host: host, name: event.message.agent)
            if case .message(let message) = event, message.isFromAgent {
                latestKinds[agent] = message.kind
                liveKindsSinceSeedBegan[agent] = message.kind
            }
            counts = counts.receiving(event, host: host, isOnScreen: isOnScreen(agent))
        case .resync:
            seed(host)
        }
    }

    /// Returns once the seeds in flight (if any) have landed or been dropped.
    func settled() async {
        for task in Array(seedTasks.values) { await task.value }
    }

    /// Drops `host`'s seed in flight and the read and live-kind notes it
    /// would have reconciled against.
    private func invalidateSeed(_ host: LeoHostID) {
        seedTasks[host]?.cancel()
        seedTasks[host] = nil
        seedTokens[host, default: 0] += 1
        readSinceSeedBegan = readSinceSeedBegan.filter { $0.host != host }
        liveKindsSinceSeedBegan = liveKindsSinceSeedBegan.filter { $0.key.host != host }
    }

    /// Its own task, so a slow `threads()` never stalls the ordered relay.
    /// A failed fetch keeps the counts as they are.
    private func seed(_ host: LeoHostID) {
        guard let client = clients[host] else { return }
        invalidateSeed(host)
        let token = seedTokens[host, default: 0]
        seedTasks[host] = Task { [weak self] in
            guard let threads = try? await client.threads() else { return }
            guard let self, token == self.seedTokens[host] else { return }
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
