import Foundation

/// Which finished items the user has already looked at, per host.
/// - **Synced** (daemon with `/agents/seen`): one `seen_at` per agent shared by
///   every client; an item is unread when it is newer than that.
/// - **Local** (older daemon): a mark of the `(bootID, revision)` last seen;
///   an item is unread when its pair differs (a daemon restart re-flags once).
/// Blocked items are never cleared by viewing, so nothing here affects them.
public struct LeoInboxSeenState: Equatable, Sendable, Codable {
    public struct Mark: Equatable, Sendable, Codable {
        public let bootID: String?
        public let revision: Int

        public init(bootID: String?, revision: Int) {
            self.bootID = bootID
            self.revision = revision
        }
    }

    public enum HostMarks: Equatable, Sendable, Codable {
        case synced([String: Date])
        case local([String: Mark])
    }

    public private(set) var hosts: [LeoHostID: HostMarks]

    public init(hosts: [LeoHostID: HostMarks] = [:]) {
        self.hosts = hosts
    }

    // MARK: Queries

    /// A host that was never seeded is local with no marks (everything unread).
    public func isUnread(_ agent: LeoAgentID, at: Date?, revision: Int?, bootID: String?) -> Bool {
        switch hosts[agent.host] ?? .local([:]) {
        case .synced(let marks):
            guard let seenAt = marks[agent.name] else { return true }
            guard let at else { return false }
            return at > seenAt
        case .local(let marks):
            guard let mark = marks[agent.name], let revision else { return true }
            return mark != Mark(bootID: bootID, revision: revision)
        }
    }

    // MARK: Updates

    /// Sets a host's mode from the daemon's `GET /agents/seen`: the map when
    /// the route exists (synced), nil on a 404 (local). Re-seeding the same
    /// mode keeps whatever is newer locally.
    public mutating func seed(host: LeoHostID, seen: [String: Date]?) {
        guard let seen else {
            if case .local = hosts[host] { return }
            hosts[host] = .local([:])
            return
        }
        if case .synced(let existing) = hosts[host] {
            hosts[host] = .synced(existing.merging(seen, uniquingKeysWith: max))
        } else {
            hosts[host] = .synced(seen)
        }
    }

    /// Records that the user looked at `agent`. Synced: forward-only, and
    /// never earlier than the item itself, so a lagging local clock can't
    /// leave it unread. Local: remembers the item's revision.
    public mutating func markSeen(_ agent: LeoAgentID, at: Date?, revision: Int?, bootID: String?, now: Date) {
        switch hosts[agent.host] ?? .local([:]) {
        case .synced(var marks):
            marks[agent.name] = max(marks[agent.name] ?? .distantPast, now, at ?? .distantPast)
            hosts[agent.host] = .synced(marks)
        case .local(var marks):
            guard let revision else { return }
            marks[agent.name] = Mark(bootID: bootID, revision: revision)
            hosts[agent.host] = .local(marks)
        }
    }

    /// "Clear Finished": marks every finished item shown; blocked ones are untouched.
    public mutating func clear(_ items: [LeoInboxItem], now: Date) {
        for item in items where !item.isBlocked {
            markSeen(item.id, at: item.at, revision: item.revision, bootID: item.bootID, now: now)
        }
    }

    /// The daemon's `agent_seen {agent, seen_at}` event (forward-only).
    public mutating func apply(host: LeoHostID, agent: String, seenAt: Date) {
        var marks: [String: Date] = [:]
        if case .synced(let existing) = hosts[host] { marks = existing }
        marks[agent] = max(marks[agent] ?? .distantPast, seenAt)
        hosts[host] = .synced(marks)
    }
}
