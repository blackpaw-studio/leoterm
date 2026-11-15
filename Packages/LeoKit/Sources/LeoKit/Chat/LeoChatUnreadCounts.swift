import Foundation

/// Unread agent messages per agent, across hosts. Immutable: every change
/// returns a new value. The daemon's read mark is the source of truth, so a
/// seed from `threads()` replaces a host's counts; live events only add to
/// them until the next seed or a read clears one.
public struct LeoChatUnreadCounts: Equatable, Sendable {
    private var counts: [LeoAgentID: Int]

    public init() {
        counts = [:]
    }

    public subscript(agent: LeoAgentID) -> Int { counts[agent] ?? 0 }

    /// Replaces every count on `host` with the daemon's `unread` per thread.
    public func seeding(_ threads: [LeoChatThread], host: LeoHostID) -> Self {
        var next = self
        next.counts = counts.filter { $0.key.host != host }
        for thread in threads where thread.unread > 0 {
            next.counts[LeoAgentID(host: host, name: thread.agent)] = thread.unread
        }
        return next
    }

    /// Adds one for a new message from the agent, unless that agent's chat
    /// is on screen (the pane marks it read instead).
    public func receiving(_ event: LeoChatEvent, host: LeoHostID, isOnScreen: Bool) -> Self {
        guard case .message(let message) = event, message.isFromAgent, !isOnScreen else { return self }
        var next = self
        next.counts[LeoAgentID(host: host, name: message.agent), default: 0] += 1
        return next
    }

    public func clearing(_ agent: LeoAgentID) -> Self {
        var next = self
        next.counts[agent] = nil
        return next
    }

    /// The capsule text: nil at 0, `99+` above 99.
    public static func badgeText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }
}
