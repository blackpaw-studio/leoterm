import Foundation
import LeoKit

/// System notifications for agent tasks that finish. Rides the existing
/// Agents ▸ Agent Notifications… opt-in and `LeoNotificationPosting`; posts
/// each (host, agent, task, `ended_at`) at most once; and stays quiet while
/// the user is already looking at that agent.
@MainActor final class LeoProgressNotifier {
    private struct Key: Hashable {
        let host: LeoHostID
        let agent: String
        let task: String
        let endedAt: Date
    }

    private let center: any LeoNotificationPosting
    private let isEnabled: () -> Bool
    /// True while the app is frontmost with that agent selected.
    private let isWatching: (LeoAgentRow.ID) -> Bool
    private let isLive: (LeoHostID) -> Bool
    private let displayName: (LeoAgentRow.ID) -> String?
    private var posted: Set<Key> = []

    init(
        center: any LeoNotificationPosting, isEnabled: @escaping () -> Bool, isWatching: @escaping (LeoAgentRow.ID) -> Bool,
        isLive: @escaping (LeoHostID) -> Bool = { _ in true }, displayName: @escaping (LeoAgentRow.ID) -> String? = { _ in nil }
    ) {
        self.center = center
        self.isEnabled = isEnabled
        self.isWatching = isWatching
        self.isLive = isLive
        self.displayName = displayName
    }

    func handle(host: LeoHostID, finishes: [LeoTaskFinish]) async {
        guard isEnabled(), isLive(host) else { return }
        for finish in finishes {
            guard let ended = finish.task.endedAt else { continue }
            let id = LeoAgentRow.ID(host: host, name: finish.agent)
            let key = Key(host: host, agent: finish.agent, task: finish.task.id, endedAt: ended)
            guard !posted.contains(key), !isWatching(id) else { continue }
            guard let notification = LeoAttentionNotification(taskFinish: finish, host: host, displayName: displayName(id)) else { continue }
            posted = posted.filter { isLive($0.host) }
            posted.insert(key)
            await center.post(notification)
        }
    }
}
