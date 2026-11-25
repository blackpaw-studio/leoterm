import Foundation

/// The Inbox row / Chats tab badge: an orange count of Blocked items; a grey
/// dot when none are blocked but a finished one is unread; nothing otherwise.
public enum LeoInboxBadge: Equatable, Sendable {
    case none
    case dot
    case count(Int)

    public init(_ inbox: LeoInbox) {
        if !inbox.blocked.isEmpty {
            self = .count(inbox.blocked.count)
        } else if inbox.finished.contains(where: \.isUnread) {
            self = .dot
        } else {
            self = .none
        }
    }
}

/// The header counts: "3 need you · 3 finished since you looked".
public struct LeoInboxSummary: Equatable, Sendable {
    public let needYou: Int
    public let unreadFinished: Int
    public let finished: Int

    public init(needYou: Int, unreadFinished: Int, finished: Int) {
        self.needYou = needYou
        self.unreadFinished = unreadFinished
        self.finished = finished
    }
}

extension LeoInbox {
    public var summary: LeoInboxSummary {
        LeoInboxSummary(needYou: blocked.count, unreadFinished: finished.filter(\.isUnread).count, finished: finished.count)
    }

    public var badge: LeoInboxBadge { LeoInboxBadge(self) }
}
