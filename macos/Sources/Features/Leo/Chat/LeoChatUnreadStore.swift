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

    private var client: any LeoChatClient
    private var host: LeoHostID
    private var seedTask: Task<Void, Never>?
    /// Identifies the seed whose answer still counts.
    private var seedToken = 0

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

    func count(for agent: LeoAgentID) -> Int { counts[agent] }

    func clear(_ agent: LeoAgentID) {
        guard counts[agent] > 0 else { return }
        counts = counts.clearing(agent)
    }

    /// `isOnScreen` says whether an agent's chat is being read right now.
    func receive(_ delivery: LeoChatFeedDelivery, isOnScreen: (LeoAgentID) -> Bool) {
        guard delivery.host == host else { return }
        switch delivery.signal {
        case .event(let event):
            let agent = LeoAgentID(host: host, name: event.message.agent)
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
        let (token, client, host) = (seedToken, client, host)
        seedTask = Task { [weak self] in
            guard let threads = try? await client.threads() else { return }
            guard let self, token == self.seedToken else { return }
            counts = counts.seeding(threads, host: host)
        }
    }
}
